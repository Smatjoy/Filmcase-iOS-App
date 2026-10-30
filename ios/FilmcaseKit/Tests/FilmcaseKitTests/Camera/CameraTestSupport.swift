// Shared helpers for the strategy / use-case tests; mirrors tests/js/fakes/config.js
// (makeConfig, PROP_* constants), tests/js/fakes/clock.js (makeClock) and the SlotAwareDevice
// in tests/js/get_camera_slots.test.js.

import Foundation
import Testing
@testable import FilmcaseKit

enum TestSupport {
    static let encodings: ClientEncodings = RecipePtpVectors.shared!.encodings

    static var propSlotCursor: UInt16 { UInt16(encodings.propSlotCursor) }
    static var propSlotName: UInt16 { UInt16(encodings.propSlotName) }
    static func code(_ name: String) -> UInt16 { UInt16(encodings.customSlotCodes[name]!) }

    /// `makeConfig(overrides)`: zero delays, 3 retries, 0.15 s backoff, unless overridden.
    static func makeConfig(_ overrides: [String: Any] = [:]) throws -> ClientConfig {
        var settings: [String: Any] = [
            "CAMERA_TRANSPORT": "browser",
            "CAMERA_VERIFY_WRITES": false,
            "CAMERA_POST_READ_DELAY_S": 0,
            "CAMERA_PRE_WRITE_DELAY_S": 0,
            "CAMERA_POST_WRITE_DELAY_S": 0,
            "CAMERA_POST_CURSOR_DELAY_S": 0,
            "CAMERA_INTER_SLOT_DELAY_S": 0,
            "CAMERA_MAX_RETRIES": 3,
            "CAMERA_RETRY_BACKOFF_S": 0.15,
            "CAMERA_USB_TIMEOUT_MS": 1500,
        ]
        for (key, value) in overrides { settings[key] = value }
        let data = try JSONSerialization.data(withJSONObject: settings)
        return ClientConfig(settings: try JSONDecoder().decode(ClientSettings.self, from: data), encodings: encodings)
    }

    /// Runtime whose sleeps are recorded on `device`'s timeline.
    static func runtime(_ device: FakePTPDevice, _ overrides: [String: Any] = [:]) throws -> CameraRuntime {
        CameraRuntime(config: try makeConfig(overrides), sleeper: device.sleeper)
    }

    /// `makeRecipe(overrides)`.
    static func makeRecipe(_ overrides: [String: JSONValue] = [:]) throws -> Recipe {
        try #require(RecipePtpVectors.shared).recipe(overrides: overrides)
    }
}

/// Records sleeps for tests whose device is not a `FakePTPDevice` (`makeClock`).
actor RecordingSleeper: CameraSleeper {
    private(set) var slept: [Double] = []

    func sleep(seconds: Double) async throws {
        slept.append(seconds)
    }
}

/// A camera whose slots hold distinct values, so a test can tell which slot a read came from.
actor SlotAwareDevice: PTPDevice {
    nonisolated let cameraName: String
    private let slots: [(name: String, filmSim: Int)]
    private let setFailuresBeforeSuccess: [UInt16: Int]
    private let setRejectionCodes: [UInt16: Int]
    private let defaultGetError: (any Error)?
    private var cursor = 1
    private var failuresLeft: [UInt16: Int]

    /// Cursor positions written, in order.
    private(set) var cursors: [Int] = []
    /// (cursor, code) for every read, so ordering can be asserted.
    private(set) var readsAtCursor: [(cursor: Int, code: UInt16)] = []
    /// Every cursor write attempted, refused ones included.
    private(set) var cursorAttempts = 0

    init(
        slots: [(name: String, filmSim: Int)], cameraName: String = "X-S10",
        setFailuresBeforeSuccess: [UInt16: Int] = [:], setRejectionCodes: [UInt16: Int] = [:],
        defaultGetError: (any Error)? = nil
    ) {
        self.slots = slots
        self.cameraName = cameraName
        self.setFailuresBeforeSuccess = setFailuresBeforeSuccess
        self.failuresLeft = setFailuresBeforeSuccess
        self.setRejectionCodes = setRejectionCodes
        self.defaultGetError = defaultGetError
    }

    func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int {
        if code == TestSupport.propSlotCursor { cursorAttempts += 1 }
        if let left = failuresLeft[code], left > 0 {
            failuresLeft[code] = left - 1
            throw CameraConnectionError("transport failure writing \(code)")
        }
        if let rc = setRejectionCodes[code] { return rc }
        if code == TestSupport.propSlotCursor {
            cursors.append(value)
            cursor = value
        }
        return 0
    }

    func getString(_ code: UInt16) async throws -> String {
        readsAtCursor.append((cursor, code))
        if let error = defaultGetError { throw error }
        return code == TestSupport.propSlotName ? slots[cursor - 1].name : ""
    }

    func getInt(_ code: UInt16) async throws -> Int {
        readsAtCursor.append((cursor, code))
        if let error = defaultGetError { throw error }
        return code == TestSupport.code("FilmSimulation") ? slots[cursor - 1].filmSim : 0
    }

    func setInt(_ code: UInt16, _ value: Int) async throws -> Int { 0 }
    func setString(_ code: UInt16, _ value: String) async throws -> Int { 0 }
}
