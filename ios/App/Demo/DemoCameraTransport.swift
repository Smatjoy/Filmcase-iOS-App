// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// A scripted X-T50 for demo mode. FakeCameraTransport/FakePTPDevice keep one value per
// property, so all seven slots would read the same name; the demo needs seven distinct
// slots, so this keeps a value table per slot and follows the slot cursor.

import FilmcaseKit
import Foundation

actor DemoCameraTransport: CameraTransport {
    nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let device: DemoSlotDevice

    init(encodings: ClientEncodings) {
        let device = DemoSlotDevice(encodings: encodings)
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.device = device
        self.events = stream
        self.continuation = continuation
        continuation.yield(.deviceAdded(name: device.cameraName))
    }

    var authorizationStatus: CameraAuthorizationStatus { .authorized }

    func requestAuthorization() async -> Bool { true }

    func openSession() async throws -> any PTPDevice { device }

    func closeSession() async {}
}

actor DemoSlotDevice: PTPDevice {
    nonisolated let cameraName = "X-T50"

    static let slots: [(name: String, filmSim: String)] = [
        ("Kodak Portra 400", "Classic Negative"),
        ("Street Chrome", "Classic Chrome"),
        ("Velvia Sky", "Velvia"),
        ("Soft Pastel", "Astia"),
        ("Night Ace", "Reala Ace"),
        ("Tri-X Look", "Acros STD"),
        ("Plain Provia", "Provia"),
    ]

    private let cursorCode: UInt16
    private let nameCode: UInt16
    private var cursor = 1
    private var names: [Int: String] = [:]
    private var values: [Int: [UInt16: Int]] = [:]

    init(encodings: ClientEncodings) {
        cursorCode = UInt16(truncatingIfNeeded: encodings.propSlotCursor)
        nameCode = UInt16(truncatingIfNeeded: encodings.propSlotName)
        let filmSimCode = encodings.customSlotCodes["FilmSimulation"].map { UInt16(truncatingIfNeeded: $0) }
        for (offset, slot) in Self.slots.enumerated() {
            let index = offset + 1
            names[index] = slot.name
            if let filmSimCode, let ptp = encodings.filmSimulationToPtp[slot.filmSim] {
                values[index] = [filmSimCode: ptp]
            }
        }
    }

    func getInt(_ code: UInt16) async throws -> Int {
        if code == cursorCode { return cursor }
        return values[cursor]?[code] ?? 0
    }

    func getString(_ code: UInt16) async throws -> String {
        code == nameCode ? (names[cursor] ?? "") : ""
    }

    func setInt(_ code: UInt16, _ value: Int) async throws -> Int {
        store(code, value)
        return 0
    }

    func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int {
        store(code, value & 0xffff)
        return 0
    }

    func setString(_ code: UInt16, _ value: String) async throws -> Int {
        if code == nameCode { names[cursor] = value }
        return 0
    }

    private func store(_ code: UInt16, _ value: Int) {
        if code == cursorCode {
            cursor = value
        } else {
            values[cursor, default: [:]][code] = value
        }
    }
}
