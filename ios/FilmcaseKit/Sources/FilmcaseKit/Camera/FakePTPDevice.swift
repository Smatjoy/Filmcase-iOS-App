// Mirrors: tests/js/fakes/ptp_device.js (FakePTPDevice) and tests/js/fakes/clock.js (makeClock),
// knob for knob. Public so the app's demo build flavor can drive the same code path.
//
// All three set* variants write to one shared store keyed by property code and the get*
// variants read from it, so a write-then-read round trip needs no configuration (that is the
// verification path). Every call and every sleep is appended to `events` in order. An actor
// serialises calls, which stands in for the JS fake's "one transaction at a time" guard.

import Foundation

public actor FakePTPDevice: ConnectableCameraDevice {
    /// One recorded interaction, in the order it happened.
    public enum Event: Equatable, Sendable {
        case connect
        case disconnect
        case getInt(UInt16)
        case getString(UInt16)
        case setInt(UInt16, Int)
        case setUInt16(UInt16, Int)
        case setString(UInt16, String)
        case sleep(Double)
    }

    public nonisolated let cameraName: String

    private var intStore: [UInt16: Int]
    private var stringStore: [UInt16: String]
    private let getErrors: [UInt16: any Error]
    private let defaultGetError: (any Error)?
    private let defaultIntGetError: (any Error)?
    private let intReadOverrides: [UInt16: Int]
    private let strReadOverrides: [UInt16: String]
    private let setErrors: [UInt16: any Error]
    private let setRejectionCodes: [UInt16: Int]
    private var setFailuresLeft: [UInt16: Int]

    /// Every call and sleep, in order. Failed and refused writes are included.
    public private(set) var events: [Event] = []

    /// - Parameters:
    ///   - getErrors: Code to error thrown on read.
    ///   - defaultGetError: Thrown for any read not in `getErrors`.
    ///   - defaultIntGetError: Thrown for any integer read; string reads still work.
    ///   - intReadOverrides: Code to value always returned, whatever was written (the camera normalising).
    ///   - setErrors: Code to error thrown on every write.
    ///   - setRejectionCodes: Code to non-zero response code; the store is left untouched.
    ///   - setFailuresBeforeSuccess: Code to a count of `CameraConnectionError`s raised before the write goes through.
    public init(
        intValues: [UInt16: Int] = [:],
        stringValues: [UInt16: String] = [:],
        cameraName: String = "X-S10",
        getErrors: [UInt16: any Error] = [:],
        defaultGetError: (any Error)? = nil,
        defaultIntGetError: (any Error)? = nil,
        intReadOverrides: [UInt16: Int] = [:],
        strReadOverrides: [UInt16: String] = [:],
        setErrors: [UInt16: any Error] = [:],
        setRejectionCodes: [UInt16: Int] = [:],
        setFailuresBeforeSuccess: [UInt16: Int] = [:]
    ) {
        self.intStore = intValues
        self.stringStore = stringValues
        self.cameraName = cameraName
        self.getErrors = getErrors
        self.defaultGetError = defaultGetError
        self.defaultIntGetError = defaultIntGetError
        self.intReadOverrides = intReadOverrides
        self.strReadOverrides = strReadOverrides
        self.setErrors = setErrors
        self.setRejectionCodes = setRejectionCodes
        self.setFailuresLeft = setFailuresBeforeSuccess
    }

    // --- derived views of `events` (the JS fake's writes / reads / sleeps) ---

    /// Every write attempted as `(code, value)`, refused and failed ones included.
    public var writes: [(code: UInt16, value: PTPPropertyValue)] {
        events.compactMap { event in
            switch event {
            case .setInt(let c, let v), .setUInt16(let c, let v): return (c, .int(v))
            case .setString(let c, let s): return (c, .string(s))
            default: return nil
            }
        }
    }

    /// Every read attempted, by code.
    public var reads: [UInt16] {
        events.compactMap { event in
            switch event {
            case .getInt(let c), .getString(let c): return c
            default: return nil
            }
        }
    }

    /// Every duration the sleeper was asked for, in order.
    public var sleeps: [Double] {
        events.compactMap { if case .sleep(let s) = $0 { return s } else { return nil } }
    }

    /// A sleeper that records into this device's `events` instead of waiting, so sleeps and
    /// device calls share one ordered timeline.
    public nonisolated var sleeper: some CameraSleeper { FakeCameraSleeper(device: self) }

    fileprivate func recordSleep(_ seconds: Double) {
        events.append(.sleep(seconds))
    }

    // --- lifecycle ---

    public func connect() async throws { events.append(.connect) }
    public func disconnect() async { events.append(.disconnect) }

    // --- reads ---

    private func checkGet(_ code: UInt16, isInt: Bool) throws {
        if let error = getErrors[code] { throw error }
        if isInt, let error = defaultIntGetError { throw error }
        if let error = defaultGetError { throw error }
    }

    public func getInt(_ code: UInt16) async throws -> Int {
        events.append(.getInt(code))
        try checkGet(code, isInt: true)
        if let override = intReadOverrides[code] { return override }
        return intStore[code] ?? 0
    }

    public func getString(_ code: UInt16) async throws -> String {
        events.append(.getString(code))
        try checkGet(code, isInt: false)
        if let override = strReadOverrides[code] { return override }
        return stringStore[code] ?? ""
    }

    // --- writes ---

    private func beforeSet(_ code: UInt16) throws {
        if let left = setFailuresLeft[code], left > 0 {
            setFailuresLeft[code] = left - 1
            throw CameraConnectionError("transport failure writing \(code)")
        }
        if let error = setErrors[code] { throw error }
    }

    public func setInt(_ code: UInt16, _ value: Int) async throws -> Int {
        events.append(.setInt(code, value))
        try beforeSet(code)
        if let rc = setRejectionCodes[code] { return rc }
        intStore[code] = value
        return 0
    }

    public func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int {
        events.append(.setUInt16(code, value))
        try beforeSet(code)
        if let rc = setRejectionCodes[code] { return rc }
        intStore[code] = value & 0xffff
        return 0
    }

    public func setString(_ code: UInt16, _ value: String) async throws -> Int {
        events.append(.setString(code, value))
        try beforeSet(code)
        if let rc = setRejectionCodes[code] { return rc }
        stringStore[code] = value
        return 0
    }
}

/// Records instead of waiting; created by `FakePTPDevice.sleeper`.
struct FakeCameraSleeper: CameraSleeper {
    let device: FakePTPDevice

    func sleep(seconds: Double) async throws {
        await device.recordSleep(seconds)
    }
}
