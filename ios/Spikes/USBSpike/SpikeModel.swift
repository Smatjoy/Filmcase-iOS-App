// Throwaway spike code (S1). Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation
import Observation

/// How the command (and out-data) bytes are handed to requestSendPTPCommand. Which one the
/// framework expects is NOT documented well enough to be certain; the spike resolves it.
enum CommandFraming: String, CaseIterable, Identifiable, Sendable {
    /// Full PTP/USB containers: 12-byte header + params; data phase as a data container.
    case fullContainer = "Full container"
    /// Operation code (uint16 LE) + params (uint32 LE each); out data is the bare payload.
    case commandOnly = "Command only"
    /// Full command container, but the out data is the bare payload (ImageCaptureCore strips the
    /// data-in header, so it likely adds the data-out header itself).
    case bareDataOut = "Bare data out"

    var id: String { rawValue }
}

struct LogEntry: Identifiable, Sendable {
    enum Level: Sendable { case info, warning, error, alarm }
    let id: Int
    let text: String
    let level: Level
}

struct SlotReading: Identifiable, Sendable {
    let index: Int
    var name: String
    var filmSim: Int?
    var note: String
    var id: Int { index }
}

private enum Prop {
    static let slotCursor: UInt16 = 0xD18C  // uint16, 1-based slot index (src/data/camera/constants.py)
    static let slotName: UInt16 = 0xD18D    // PTP string
    static let filmSim: UInt16 = 0xD192     // custom-slot FilmSimulation (CUSTOM_SLOT_CODES)
}

private struct PTPCall {
    var response: PTPResponse?
    var payload: [UInt8] = []
    var timedOut = false
    var error: ErrorInfo?
    var ms: Double = 0

    var ok: Bool { !timedOut && error == nil && response?.code == rcOk }
}

@MainActor
@Observable
final class SpikeModel {
    // MARK: Observable state
    var log: [LogEntry] = []
    var devices: [DeviceSnapshot] = []
    var selectedDeviceID: String?
    var controlStatus = "(not read yet)"
    var contentsStatus = "(not read yet)"
    var sessionOpen = false
    var isBusy = false
    var framing: CommandFraming = .fullContainer
    var slots: [SlotReading] = []
    var summary = ""
    var sawNotAuthorized = false
    var exportURL: URL?

    // MARK: Private state
    @ObservationIgnored private let bridge = ICCameraBridge()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var plainLines: [String] = []
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var nextTx: UInt32 = 1
    @ObservationIgnored private var cursor: Int?
    @ObservationIgnored private let clock = ContinuousClock()

    var selectedDevice: DeviceSnapshot? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    // MARK: Lifecycle

    func start() {
        guard eventTask == nil else { return }
        let stream = bridge.events
        eventTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
        append("Start. Browsing for cameras (ICDeviceBrowser, camera + local mask).", .info)
        bridge.startBrowsing()
        refreshAuthStatus(label: "initial")
    }

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .deviceAdded(let snap):
            devices.removeAll { $0.id == snap.id }
            devices.append(snap)
            if selectedDeviceID == nil { selectedDeviceID = snap.id }
            append("Device added: \(snap.name) uuid=\(snap.uuid) transport=\(snap.transport) hasOpenSession=\(snap.hasOpenSession)", .info)
            logCapabilities(snap)
        case .deviceRemoved(let id):
            devices.removeAll { $0.id == id }
            if selectedDeviceID == id { selectedDeviceID = devices.first?.id }
            sessionOpen = false
            cursor = nil
            append("Device removed (id \(id))", .warning)
        case .sessionOpened(let text):
            sessionOpen = (text == nil)
            append("Delegate: didOpenSession error=\(text ?? "none")", text == nil ? .info : .error)
        case .sessionClosed(let text):
            sessionOpen = false
            cursor = nil
            append("Delegate: didCloseSession error=\(text ?? "none")", text == nil ? .info : .warning)
        case .deviceReady(let which):
            append("Delegate: \(which)", .info)
        case .capabilityChanged(let snap):
            replace(snap)
            append("Delegate: cameraDeviceDidChangeCapability", .info)
            logCapabilities(snap)
        case .ptpEvent(let hex):
            append("PTP event from camera: \(hex)", .info)
        case .note(let text):
            append("note: \(text)", .info)
        }
    }

    private func replace(_ snap: DeviceSnapshot) {
        if let i = devices.firstIndex(where: { $0.id == snap.id }) {
            devices[i] = snap
        } else {
            devices.append(snap)
        }
    }

    private func logCapabilities(_ snap: DeviceSnapshot) {
        append("capabilities: \(snap.capabilities.joined(separator: ", "))", .info)
        append("ICCameraDeviceCanAcceptPTPCommands present: \(snap.canAcceptPTPCommands)",
               snap.canAcceptPTPCommands ? .info : .warning)
    }

    func selectDevice(_ id: String) {
        selectedDeviceID = id
        bridge.select(id: id)
    }

    // MARK: Authorization

    private func refreshAuthStatus(label: String) {
        controlStatus = bridge.controlAuthorizationDescription
        contentsStatus = bridge.contentsAuthorizationDescription
        append("[\(label)] controlAuthorizationStatus=\(controlStatus) contentsAuthorizationStatus=\(contentsStatus)", .info)
    }

    func authorizeControl() async {
        await perform("Authorize (requestControlAuthorization)") {
            refreshAuthStatus(label: "before")
            do {
                let reported = try await bridge.requestControlAuthorization()
                append("requestControlAuthorization completion status: \(reported)", .info)
            } catch {
                append("requestControlAuthorization failed: \(error)", .error)
            }
            refreshAuthStatus(label: "after")
            if !controlStatus.hasPrefix("authorized") {
                append("Control authorization is not .authorized (iOS 26.1 beta forum report: stays notDetermined). Try the contents fallback, then Open session anyway.", .warning)
            }
        }
    }

    func authorizeContents() async {
        await perform("Authorize contents (fallback experiment)") {
            refreshAuthStatus(label: "before")
            do {
                let reported = try await bridge.requestContentsAuthorization()
                append("requestContentsAuthorization completion status: \(reported)", .info)
            } catch {
                append("requestContentsAuthorization failed: \(error)", .error)
            }
            refreshAuthStatus(label: "after")
        }
    }

    // MARK: Session

    func openSession() async {
        await perform("Open session (requestOpenSession)") {
            await openSessionInline()
        }
    }

    private func openSessionInline() async {
        let t0 = clock.now
        do {
            try await bridge.openSession()
            sessionOpen = true
            append("Session open OK in \(ms(since: t0)) ms", .info)
        } catch {
            sessionOpen = bridge.hasOpenSession()
            append("Open session failed in \(ms(since: t0)) ms: \(error)", .error)
            noteIfNotAuthorized(error)
        }
        if let snap = bridge.refreshedSnapshot() { replace(snap) }
    }

    func closeSession() async {
        await perform("Close session (requestCloseSession)") {
            let t0 = clock.now
            do {
                try await bridge.closeSession()
                sessionOpen = false
                cursor = nil
                append("Session closed in \(ms(since: t0)) ms", .info)
            } catch {
                append("Close session failed in \(ms(since: t0)) ms: \(error)", .error)
            }
        }
    }

    private func noteIfNotAuthorized(_ error: any Error) {
        if case BridgeError.icc(let info) = error, info.isNotAuthorized {
            sawNotAuthorized = true
        }
    }

    // MARK: PTP plumbing

    private func ptp(_ op: UInt16, params: [UInt32] = [], outPayload: [UInt8]? = nil) async -> PTPCall {
        let tx = nextTx
        nextTx &+= 1
        let mode = framing

        let command: [UInt8]
        switch mode {
        case .fullContainer, .bareDataOut:
            command = commandPacket(code: op, txId: tx, params: params)
        case .commandOnly:
            command = packUInt16LE(op) + params.flatMap { packUInt32LE($0) }
        }
        var outBytes: [UInt8] = []
        if let payload = outPayload {
            switch mode {
            case .fullContainer: outBytes = dataPacket(code: op, txId: tx, payload: payload)
            case .commandOnly, .bareDataOut: outBytes = payload
            }
        }

        var call = PTPCall()
        var raw: RawPTPResult?
        let t0 = clock.now
        do {
            raw = try await bridge.sendPTP(command: Data(command), outData: Data(outBytes))
        } catch {
            if case BridgeError.timeout = error {
                call.timedOut = true
            } else {
                call.error = ErrorInfo(error)
            }
        }
        call.ms = ms(since: t0)

        var responseHex = "-"
        var inHex = "-"
        var parseNote = ""
        if let raw {
            call.error = raw.error
            responseHex = hex(raw.response)
            inHex = hex(raw.inData)
            do {
                call.response = try parseResponse(raw.response)
            } catch {
                parseNote = " response-parse-failed(\(error))"
            }
            call.payload = dataPhasePayload(raw.inData)
            if !raw.inData.isEmpty {
                parseNote += " in-data-has-header=\(hasContainerHeader(raw.inData))"
            }
        }

        let errText: String
        if call.timedOut {
            errText = "TIMEOUT"
        } else if let e = call.error {
            errText = "\(e.domain) \(e.code) \(e.message)"
        } else {
            errText = "none"
        }
        let rc = call.response.map { String(format: "0x%04X", $0.code) } ?? "-"
        let line = "PTP \(opName(op)) tx=\(tx) framing=\(mode.rawValue) params=[\(params.map { String(format: "0x%X", $0) }.joined(separator: ","))] "
            + "out=[\(hex(outBytes))] cmd=[\(hex(command))] resp=[\(responseHex)] rc=\(rc) in=[\(inHex)] err=\(errText) \(fmt(call.ms)) ms\(parseNote)"
        let level: LogEntry.Level
        if call.error?.isNotAuthorized == true {
            sawNotAuthorized = true
            level = .alarm
            append(line, level)
            append("!!! -21249 ICReturnPTPNotAuthorizedToSendCommand: authorization problem (see Authorize / contents fallback) !!!", .alarm)
            return call
        }
        level = (call.timedOut || call.error != nil) ? .error : (call.ok ? .info : .warning)
        append(line, level)
        return call
    }

    private func hasContainerHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= headerBytes, let type = try? readUInt16LE(bytes, 4) else { return false }
        return type == ptpData || type == ptpResponse
    }

    /// In-data may arrive as a full data container or as the bare payload; log shows which.
    private func dataPhasePayload(_ inData: [UInt8]) -> [UInt8] {
        if hasContainerHeader(inData) {
            return Array(inData.dropFirst(headerBytes))
        }
        return inData
    }

    private func setCursor(_ index: Int) async -> Bool {
        let call = await ptp(ocSetDevicePropValue, params: [UInt32(Prop.slotCursor)], outPayload: packUInt16LE(UInt16(index)))
        if call.ok { cursor = index }
        return call.ok
    }

    private func readSlotName() async -> String? {
        let call = await ptp(ocGetDevicePropValue, params: [UInt32(Prop.slotName)])
        guard call.ok else { return nil }
        guard let decoded = try? decodePtpString(call.payload, 0) else {
            append("slot name decode failed", .warning)
            return nil
        }
        return decoded.value
    }

    /// Same rule as the Python get_property_int: >=4 bytes signed int32, 2-3 uint16, 1 byte.
    private func readInt(_ code: UInt16) async -> Int? {
        let call = await ptp(ocGetDevicePropValue, params: [UInt32(code)])
        guard call.ok else { return nil }
        let p = call.payload
        if p.count >= 4, let v = try? readInt32LE(p, 0) { return Int(v) }
        if p.count >= 2, let v = try? readUInt16LE(p, 0) { return Int(v) }
        if p.count >= 1 { return Int(p[0]) }
        return 0
    }

    private func writeSlotName(_ name: String) async -> Bool {
        guard let payload = try? encodePtpString(name) else {
            append("encodePtpString failed for \(name)", .error)
            return false
        }
        let call = await ptp(ocSetDevicePropValue, params: [UInt32(Prop.slotName)], outPayload: payload)
        return call.ok
    }

    private func settle(_ milliseconds: Int = 100) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: Actions

    func readSlots() async {
        await perform("Read slots C1-C7") {
            var result: [SlotReading] = []
            for index in 1...7 {
                guard await setCursor(index) else {
                    result.append(SlotReading(index: index, name: "?", filmSim: nil, note: "set cursor failed"))
                    continue
                }
                await settle()
                let name = await readSlotName()
                let film = await readInt(Prop.filmSim)
                result.append(SlotReading(
                    index: index,
                    name: name ?? "?",
                    filmSim: film,
                    note: (name == nil || film == nil) ? "read failed" : ""
                ))
                await settle(50)
            }
            slots = result
            for s in result {
                append("C\(s.index): name=\"\(s.name)\" filmSim(0xD192)=\(s.filmSim.map(String.init) ?? "nil") \(s.note)", .info)
            }
        }
    }

    func writeC7Name() async {
        await perform("Write C7 name (FCTEST, then restore)") {
            let testName = "FCTEST"
            guard await setCursor(7) else {
                summary = "C7 test aborted: set cursor failed"
                append(summary, .error)
                return
            }
            await settle()
            guard let original = await readSlotName() else {
                summary = "C7 test aborted: could not read original name"
                append(summary, .error)
                return
            }
            append("C7 original name: \"\(original)\"", .info)

            let wrote = await writeSlotName(testName)
            await settle()
            let readBack = await readSlotName()
            let writeVerified = (readBack == testName)
            append("C7 write \(testName): sent-ok=\(wrote) readback=\"\(readBack ?? "nil")\" verified=\(writeVerified)",
                   writeVerified ? .info : .warning)

            // Always attempt to restore, even if the write looked like it failed.
            let restored = await writeSlotName(original)
            await settle()
            let finalName = await readSlotName()
            let restoreVerified = (finalName == original)
            append("C7 restore \"\(original)\": sent-ok=\(restored) readback=\"\(finalName ?? "nil")\" verified=\(restoreVerified)",
                   restoreVerified ? .info : .error)
            summary = "C7 write verified=\(writeVerified), restore verified=\(restoreVerified)"
            if !restoreVerified {
                append("!!! C7 NAME NOT RESTORED. Original was \"\(original)\". Fix it on the camera menu if needed. !!!", .alarm)
            }
        }
    }

    func stallDrill() async {
        await perform("Stall drill (20 x GetDevicePropValue 0xD18D)") {
            let slot = cursor ?? 1
            guard await setCursor(slot) else {
                summary = "Stall drill aborted: set cursor failed"
                append(summary, .error)
                return
            }
            await settle()

            var okCount = 0
            var timeouts = 0
            var otherErrors = 0
            var durations: [Double] = []
            var recoveriesTried = 0
            var recoveriesOK = 0

            for i in 1...20 {
                let call = await ptp(ocGetDevicePropValue, params: [UInt32(Prop.slotName)])
                durations.append(call.ms)
                if call.timedOut {
                    timeouts += 1
                    append("drill #\(i): TIMEOUT", .error)
                    if recoveriesTried < 3 {
                        recoveriesTried += 1
                        let recovered = await recoverSession(cursor: slot)
                        if recovered { recoveriesOK += 1 }
                        append("drill #\(i): recovery (close, reopen, restore cursor C\(slot)) recovered=\(recovered)",
                               recovered ? .warning : .alarm)
                    }
                } else if call.ok {
                    okCount += 1
                } else {
                    otherErrors += 1
                    append("drill #\(i): failed (non-timeout)", .error)
                }
            }
            let total = durations.reduce(0, +)
            let minD = durations.min() ?? 0
            let maxD = durations.max() ?? 0
            let avg = durations.isEmpty ? 0 : total / Double(durations.count)
            summary = "Stall drill: ok=\(okCount) timeouts=\(timeouts) otherErrors=\(otherErrors) "
                + "ms min/avg/max=\(fmt(minD))/\(fmt(avg))/\(fmt(maxD)) recoveries \(recoveriesOK)/\(recoveriesTried) ok"
            append(summary, timeouts == 0 && otherErrors == 0 ? .info : .warning)
        }
    }

    private func recoverSession(cursor slot: Int) async -> Bool {
        append("recovery: requestCloseSession", .warning)
        do { try await bridge.closeSession() } catch { append("recovery: close failed: \(error)", .error) }
        sessionOpen = false
        self.cursor = nil
        await settle(500)
        append("recovery: requestOpenSession", .warning)
        do {
            try await bridge.openSession()
            sessionOpen = true
        } catch {
            append("recovery: reopen failed: \(error)", .error)
            return false
        }
        await settle(300)
        guard await setCursor(slot) else { return false }
        await settle()
        return await readSlotName() != nil
    }

    // MARK: Export

    func prepareExport() {
        let stamp = Date.now.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usbspike-\(stamp).txt")
        let header = "USBSpike log, framing=\(framing.rawValue), control=\(controlStatus), contents=\(contentsStatus)\n"
        let body = header + plainLines.joined(separator: "\n") + "\n"
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            append("Log written to \(url.lastPathComponent) (\(plainLines.count) lines). Use the share button.", .info)
        } catch {
            append("Export failed: \(error)", .error)
        }
    }

    func clearLog() {
        log.removeAll()
        plainLines.removeAll()
        exportURL = nil
    }

    // MARK: Helpers

    private func perform(_ title: String, _ work: () async -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        append("=== \(title) [framing: \(framing.rawValue)] ===", .info)
        await work()
    }

    private func append(_ text: String, _ level: LogEntry.Level) {
        let stamped = "\(Date.now.ISO8601Format()) \(text)"
        plainLines.append(stamped)
        log.append(LogEntry(id: nextLogID, text: text, level: level))
        nextLogID += 1
    }

    private func ms(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: clock.now)
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        let limit = 256
        let shown = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return bytes.count > limit ? shown + " ...(\(bytes.count) bytes)" : shown
    }

    private func opName(_ op: UInt16) -> String {
        switch op {
        case ocGetDevicePropValue: return "GetDevicePropValue"
        case ocSetDevicePropValue: return "SetDevicePropValue"
        case ocGetDeviceInfo: return "GetDeviceInfo"
        default: return String(format: "op0x%04X", op)
        }
    }
}
