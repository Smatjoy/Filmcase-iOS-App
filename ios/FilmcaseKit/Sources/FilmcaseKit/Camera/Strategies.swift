// Mirrors: src/domain/camera/strategies.py and src/interfaces/static/js/camera/domain/strategies.js
// (PerPropertyStrategy, getStrategy, RecipeWriteError (see CameraErrors.swift), _retry, _codeToPropName)
// and makeSlotState / _filmSimName from domain/queries.js. ADR 021.
//
// A strategy owns the model-specific algorithm for reading slots and pushing a recipe; a use
// case resolves one from the camera model (getStrategy) and delegates to it. The device is
// passed in already connected; the strategy never manages the connection lifecycle.
// Where Python reads capabilities from a CameraProfile, this reads the served encodings.

import Foundation

/// One custom slot as read from the camera (JS `makeSlotState`).
public struct SlotState: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let filmSimPtp: Int
    public let filmSimName: String

    public init(index: Int, name: String, filmSimPtp: Int, filmSimName: String) {
        self.index = index
        self.name = name
        self.filmSimPtp = filmSimPtp
        self.filmSimName = filmSimName
    }
}

/// JS `makeSlotState`: names the film simulation, or `Unknown(n)` for a value this build has
/// never heard of (a blank cell would read as an empty slot).
public func makeSlotState(index: Int, name: String, filmSimPtp: Int, encodings: ClientEncodings) -> SlotState {
    let filmSimName = encodings.filmSimulationToPtp.first { $0.value == filmSimPtp }?.key
        ?? "Unknown(\(filmSimPtp))"
    return SlotState(index: index, name: name, filmSimPtp: filmSimPtp, filmSimName: filmSimName)
}

/// The per-model algorithm for reading slots and pushing a recipe.
public protocol CameraStrategy: Sendable {
    func readSlots(_ device: some PTPDevice, slotCount: Int, runtime: CameraRuntime) async throws -> [SlotState]
    func validateRecipe(_ recipe: Recipe, encodings: ClientEncodings) throws
    func pushRecipe(_ device: some PTPDevice, recipe: Recipe, slotIndex: Int, runtime: CameraRuntime) async throws
}

/// Map PTP codes back to the names a person recognises ("HighLightTone", not "0xd19d").
private func codeToPropName(_ encodings: ClientEncodings) -> [UInt16: String] {
    var names: [UInt16: String] = [UInt16(truncatingIfNeeded: encodings.propSlotName): "SlotName"]
    for (name, code) in encodings.customSlotCodes {
        names[UInt16(truncatingIfNeeded: code)] = name
    }
    return names
}

/// Call `fn` until it succeeds, retrying only transport failures. A `CameraWriteError`
/// propagates immediately: the camera answered and refused.
private func retry<T: Sendable>(
    runtime: CameraRuntime, _ fn: () async throws -> T
) async throws -> T {
    let maxRetries = runtime.config.settings.cameraMaxRetries
    let backoff = runtime.config.settings.cameraRetryBackoffS
    var lastError = CameraConnectionError("no retries attempted")
    var attempt = 1
    while attempt <= maxRetries {
        if attempt > 1 {
            try await runtime.sleep(backoff * Double(1 << (attempt - 2)))
        }
        attempt += 1
        do {
            return try await fn()
        } catch let error as CameraConnectionError {
            lastError = error
        }
    }
    throw lastError
}

/// Strategy for bodies with the custom-slot PTP property interface (X-S10, X-T3+).
/// Reads and writes each recipe field as its own device property, selecting the target slot
/// via the slot cursor.
public struct PerPropertyStrategy: CameraStrategy {
    public init() {}

    /// Read every custom slot (1...slotCount), name and film simulation. Sequential on
    /// purpose: each read depends on the cursor written before it.
    public func readSlots(
        _ device: some PTPDevice, slotCount: Int, runtime: CameraRuntime
    ) async throws -> [SlotState] {
        let encodings = runtime.config.encodings
        let settings = runtime.config.settings
        let nameCode = UInt16(truncatingIfNeeded: encodings.propSlotName)
        guard let filmSimRaw = encodings.customSlotCodes["FilmSimulation"] else {
            throw RecipeConversionError.missingEncoding("custom_slot_codes.FilmSimulation")
        }
        let filmSimCode = UInt16(truncatingIfNeeded: filmSimRaw)

        var states: [SlotState] = []
        var index = 1
        while index <= slotCount {
            if index > 1 {
                try await runtime.sleep(settings.cameraInterSlotDelayS)
            }
            try await setCursorWithRetry(device, slotIndex: index, runtime: runtime)
            // The camera needs a moment to settle on the new slot; reading too soon returns
            // the previous slot's values, which looks like a correct answer.
            try await runtime.sleep(settings.cameraPostCursorDelayS)

            let name = try await retry(runtime: runtime) { try await device.getString(nameCode) }
            let filmSimPtp = try await retry(runtime: runtime) { try await device.getInt(filmSimCode) }

            states.append(makeSlotState(index: index, name: name, filmSimPtp: filmSimPtp, encodings: encodings))
            index += 1
        }
        return states
    }

    /// Throws `RecipeValidationError` for a value the camera cannot take.
    public func validateRecipe(_ recipe: Recipe, encodings: ClientEncodings) throws {
        try validateRecipeForCamera(recipe, encodings: encodings)
    }

    /// Write a recipe to a custom slot.
    ///
    /// Order: every write after the first lands in whichever slot the cursor points at, and
    /// the colour temperature must precede the two white balance shifts. Nothing runs
    /// concurrently. Failure: a refused property is recorded and the rest still written; a
    /// camera that stops answering ends the sequence.
    ///
    /// - Throws: validation errors, `CameraConnectionError` (camera gone, or cursor refused),
    ///   `RecipeWriteError` naming the properties that did not write or verify.
    public func pushRecipe(
        _ device: some PTPDevice, recipe: Recipe, slotIndex: Int, runtime: CameraRuntime
    ) async throws {
        let encodings = runtime.config.encodings
        let settings = runtime.config.settings

        // --- Step 1: point the camera at the slot (retried, like the JS) ---
        do {
            try await setCursorWithRetry(device, slotIndex: slotIndex, runtime: runtime)
        } catch let error as CameraWriteError {
            // A refusal is reported as a connection failure: nothing has been written yet.
            throw CameraConnectionError("Failed to set slot cursor to slot \(slotIndex) (rc=\(error.rc))")
        }

        try await runtime.sleep(settings.cameraPreWriteDelayS)

        // --- Step 2: validate and convert, before anything else is written ---
        let ptpItems = ptpValueItems(try recipeToPtpValues(recipe, encodings: encodings), encodings: encodings)

        // --- Step 3: write the name, then every property, in order ---
        var allWrites: [(code: UInt16, value: PTPPropertyValue)] = [
            (UInt16(truncatingIfNeeded: encodings.propSlotName), .string(recipe.name)),
        ]
        allWrites += ptpItems.map { ($0.code, .int($0.value)) }
        var failedCodes = allWrites.map(\.code)
        var written: [(code: UInt16, value: PTPPropertyValue)] = []

        for (code, value) in allWrites {
            try await runtime.sleep(settings.cameraPreWriteDelayS)

            var succeeded = false
            do {
                try await setPropWithRetry(device, code: code, value: value, runtime: runtime)
                succeeded = true
            } catch let error as CameraConnectionError {
                // The camera is gone; carrying on would spend three retries on every remaining property.
                throw error
            } catch is CameraWriteError {
                // Refused, but the camera is still listening: report this one at the end.
            }

            if succeeded {
                if let at = failedCodes.firstIndex(of: code) { failedCodes.remove(at: at) }
                written.append((code, value))
            }

            // Paid even after a refusal: the camera still handled a request.
            try await runtime.sleep(settings.cameraPostWriteDelayS)
        }

        // --- Step 4: read back what reported success ---
        if settings.cameraVerifyWrites {
            let grainCode = encodings.customSlotCodes["GrainEffect"].map { UInt16(truncatingIfNeeded: $0) }
            // Grain Off is written as a sentinel the camera normalises, so its read-back never matches.
            let verifiable = written.filter { code, value in
                !(code == grainCode && value == .int(encodings.grainOffSentinel))
            }
            failedCodes += try await verifyWrittenProperties(device, written: verifiable, runtime: runtime)
        }

        if !failedCodes.isEmpty {
            let names = codeToPropName(encodings)
            throw RecipeWriteError(failedProperties: failedCodes.map { names[$0] ?? "0x" + String($0, radix: 16) })
        }
    }
}

/// Return the strategy that drives a camera model. Every model resolves to the per-property
/// strategy today (ADR 021); the X-T2 backup-blob strategy is selected here when it lands.
public func getStrategy(cameraName: String) -> PerPropertyStrategy {
    PerPropertyStrategy()
}
