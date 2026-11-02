// Back up before overwriting: read the target slot, store it, then push. Restore writes a
// stored backup back and verifies it. Every outcome is one of three results, never a thrown
// error for something the person should see (docs/ios_app_plan.md, "Never write without
// validation"): verified, partially failed with named properties, or connection lost.

import Foundation

public enum SlotPushResult: Equatable, Sendable {
    /// Every property was written and read back as written.
    case verified
    /// The camera answered but these properties did not take (names as the server serves them).
    case partiallyFailed([String])
    /// The camera went away, or never answered after recovery. Nothing more can be written.
    case connectionLost
}

/// A push or restore that must not go ahead. Nothing was written to the slot.
public enum SlotBackupError: Error, Equatable, Sendable {
    /// The slot is outside the camera model's custom slots, or the model has none.
    case slotOutOfRange(slot: Int, slotCount: Int)
    /// The backup could not be stored, so the slot was left alone.
    case backupNotSaved(String)
    /// The backup was taken from a different camera model.
    case wrongCamera(backup: String, connected: String)
}

public struct SlotBackupWorkflow: Sendable {
    let runner: any CameraOperationRunner
    let store: any BackupStore
    let runtime: CameraRuntime
    let clock: any FilmcaseClock

    public init(
        runner: any CameraOperationRunner, store: any BackupStore,
        runtime: CameraRuntime, clock: any FilmcaseClock = SystemClock()
    ) {
        self.runner = runner
        self.store = store
        self.runtime = runtime
        self.clock = clock
    }

    /// Read the target slot, store it, then write *recipe* into it.
    ///
    /// The slot is not touched (beyond pointing the cursor at it to read it) until the backup
    /// is stored. A backup that cannot be read because the camera is gone returns
    /// `.connectionLost`; one that cannot be stored throws `backupNotSaved`.
    /// - Throws: `SlotBackupError`, `RecipeValidationError`/`RecipeConversionError` for a
    ///   recipe the camera cannot take (before anything is read).
    public func push(_ recipe: Recipe, to slot: Int) async throws -> SlotPushResult {
        guard let cameraName = await runner.cameraName else { return .connectionLost }
        try checkSlot(slot, cameraName: cameraName)
        try getStrategy(cameraName: cameraName).validateRecipe(recipe, encodings: runtime.config.encodings)

        let runtime = self.runtime
        guard try await backUp(slot: slot) else { return .connectionLost }

        do {
            try await runner.run("Push to C\(slot)") { device in
                try await pushRecipeToCamera(device, recipe: recipe, slotIndex: slot, runtime: runtime)
            }
            return .verified
        } catch let error as RecipeWriteError {
            return .partiallyFailed(error.failedProperties)
        } catch {
            if isConnectionFailure(error) { return .connectionLost }
            throw error
        }
    }

    /// Write a stored backup back into its slot and verify every property.
    ///
    /// Like a push, a restore reads what the slot holds now and stores it first, so a restore
    /// never destroys the only copy of anything. Those backups pile up as history; the oldest
    /// per slot stays the original.
    /// - Throws: `SlotBackupError.wrongCamera` if a different model is connected;
    ///   `backupNotSaved` (the slot is left alone) if the current contents could not be stored.
    public func restore(_ backup: SlotBackup) async throws -> SlotPushResult {
        guard let cameraName = await runner.cameraName else { return .connectionLost }
        guard cameraName == backup.cameraName else {
            throw SlotBackupError.wrongCamera(backup: backup.cameraName, connected: cameraName)
        }
        try checkSlot(backup.slotIndex, cameraName: cameraName)

        let runtime = self.runtime
        guard try await backUp(slot: backup.slotIndex) else { return .connectionLost }
        do {
            let failed = try await runner.run("Restore C\(backup.slotIndex)") { device in
                try await writeBackup(backup, to: device, runtime: runtime)
            }
            return failed.isEmpty ? .verified : .partiallyFailed(failed)
        } catch {
            if isConnectionFailure(error) { return .connectionLost }
            throw error
        }
    }

    /// Read *slot* and store it. False when the camera went away before it could be read;
    /// throws `backupNotSaved` when the store refused it.
    private func backUp(slot: Int) async throws -> Bool {
        let runtime = self.runtime
        let clock = self.clock
        let backup: SlotBackup
        do {
            backup = try await runner.run("Back up C\(slot)") { device in
                try await captureSlot(device, slot: slot, runtime: runtime, capturedAt: clock.now)
            }
        } catch {
            if isConnectionFailure(error) { return false }
            throw error
        }
        do {
            try await store.save(backup)
        } catch {
            throw SlotBackupError.backupNotSaved(String(describing: error))
        }
        return true
    }

    func checkSlot(_ slot: Int, cameraName: String) throws {
        let slotCount = customSlotCount(cameraName: cameraName, encodings: runtime.config.encodings)
        guard slotCount > 0, (1...slotCount).contains(slot) else {
            throw SlotBackupError.slotOutOfRange(slot: slot, slotCount: slotCount)
        }
    }
}

/// True for errors that mean the camera is not there: a failed transport, or a connection
/// that is not ready. `ConnectionError.busy` is a caller bug and is not one of them.
func isConnectionFailure(_ error: any Error) -> Bool {
    if error is CameraConnectionError { return true }
    if case ConnectionError.notReady = error { return true }
    return false
}

/// Read a slot's name and every property in the server's write order.
func captureSlot(
    _ device: some PTPDevice, slot: Int, runtime: CameraRuntime, capturedAt: Date
) async throws -> SlotBackup {
    let encodings = runtime.config.encodings
    let settings = runtime.config.settings
    do {
        try await setCursorWithRetry(device, slotIndex: slot, runtime: runtime)
    } catch let error as CameraWriteError {
        throw CameraConnectionError("Failed to set slot cursor to slot \(slot) (rc=\(error.rc))")
    }
    try await runtime.sleep(settings.cameraPostCursorDelayS)

    let slotName = try await device.getString(UInt16(truncatingIfNeeded: encodings.propSlotName))
    try await runtime.sleep(settings.cameraPostReadDelayS)

    var properties: [BackupProperty] = []
    for name in encodings.writeOrder {
        guard let raw = encodings.customSlotCodes[name] else { continue }
        let code = UInt16(truncatingIfNeeded: raw)
        let value = try await device.getInt(code)
        try await runtime.sleep(settings.cameraPostReadDelayS)
        properties.append(BackupProperty(name: name, code: code, value: value))
    }
    return SlotBackup(
        cameraName: device.cameraName, slotIndex: slot, capturedAt: capturedAt,
        slotName: slotName, properties: properties)
}

/// Write a backup's name and properties, then read them all back. Returns the names that
/// were refused or did not read back as written; throws `CameraConnectionError` if the
/// camera stops answering.
func writeBackup(
    _ backup: SlotBackup, to device: some PTPDevice, runtime: CameraRuntime
) async throws -> [String] {
    let settings = runtime.config.settings
    let nameCode = UInt16(truncatingIfNeeded: runtime.config.encodings.propSlotName)
    do {
        try await setCursorWithRetry(device, slotIndex: backup.slotIndex, runtime: runtime)
    } catch let error as CameraWriteError {
        throw CameraConnectionError("Failed to set slot cursor to slot \(backup.slotIndex) (rc=\(error.rc))")
    }

    var writes: [(code: UInt16, value: PTPPropertyValue)] = [(nameCode, .string(backup.slotName))]
    writes += restorableProperties(of: backup, encodings: runtime.config.encodings).map { ($0.code, .int($0.value)) }
    var names: [UInt16: String] = [nameCode: "SlotName"]
    for property in backup.properties { names[property.code] = property.name }

    var failed: [UInt16] = []
    var written: [(code: UInt16, value: PTPPropertyValue)] = []
    for (code, value) in writes {
        try await runtime.sleep(settings.cameraPreWriteDelayS)
        do {
            try await setPropWithRetry(device, code: code, value: value, runtime: runtime)
            written.append((code, value))
        } catch is CameraWriteError {
            failed.append(code)
        }
        try await runtime.sleep(settings.cameraPostWriteDelayS)
    }
    failed += try await verifyWrittenProperties(device, written: written, runtime: runtime)
    return failed.map { names[$0] ?? formatCode($0) }
}

/// The properties a restore writes back: every stored one except those that do not apply to
/// the slot's own settings, which a push never writes either (`recipeToPtpValues`). The camera
/// keeps a value for them anyway and reads it back, but refuses it as a write: the colour
/// temperature when white balance is not Kelvin, and monochrome toning on a colour simulation.
/// Writing them would only report a failure for a setting the slot does not use.
func restorableProperties(of backup: SlotBackup, encodings: ClientEncodings) -> [BackupProperty] {
    let values = Dictionary(backup.properties.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    return backup.properties.filter { property in
        switch property.name {
        case "WhiteBalanceColorTemperature":
            guard let wb = values["WhiteBalance"], let kelvin = encodings.whiteBalanceToPtp["Kelvin"] else { return true }
            return wb == kelvin
        case "MonochromaticColorWarmCool", "MonochromaticColorMagentaGreen":
            guard let sim = values["FilmSimulation"] else { return true }
            return monochromeSimulations(encodings).contains(sim)
        default:
            return true
        }
    }
}

/// The film simulations that take monochrome toning: the Acros and Monochrome families.
func monochromeSimulations(_ encodings: ClientEncodings) -> Set<Int> {
    Set(encodings.filmSimulationToPtp.filter { $0.key.hasPrefix("Acros") || $0.key.hasPrefix("Monochrome") }.values)
}
