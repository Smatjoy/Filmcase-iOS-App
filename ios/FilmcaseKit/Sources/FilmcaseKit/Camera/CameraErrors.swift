// Mirrors: CameraConnectionError / CameraWriteError and formatCode / formatRc / formatValue in
// src/domain/camera/ptp_device.py and src/interfaces/static/js/camera/vendor/ptp_device.js,
// plus RecipeWriteError in src/domain/camera/strategies.py / domain/strategies.js.

import Foundation

/// A PTP property value as written: the slot name is the only string, everything else an integer.
public enum PTPPropertyValue: Equatable, Sendable {
    case int(Int)
    case string(String)
}

/// Raised when the camera is not reachable or the transport fails.
public struct CameraConnectionError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Raised when the camera actively rejects a property write (non-zero rc).
public struct CameraWriteError: Error, Equatable, Sendable {
    public let code: UInt16
    public let value: PTPPropertyValue
    public let rc: Int

    public init(code: UInt16, value: PTPPropertyValue, rc: Int) {
        self.code = code
        self.value = value
        self.rc = rc
    }

    public var message: String {
        "Camera rejected write of PTP property \(formatCode(code)) = \(formatValue(value)) (rc=\(formatRc(rc)))"
    }
}

/// Raised when one or more properties could not be written or verified.
public struct RecipeWriteError: Error, Equatable, Sendable {
    /// Names, in the order they were attempted.
    public let failedProperties: [String]

    public init(failedProperties: [String]) {
        self.failedProperties = failedProperties
    }

    public var message: String {
        let shown = failedProperties.map { "'\($0)'" }.joined(separator: ", ")
        return "Recipe write incomplete: \(failedProperties.count) property/properties failed ([\(shown)])"
    }
}

/// Format a PTP property code as `0xD18C`.
public func formatCode(_ code: UInt16) -> String {
    let hex = String(code, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
}

/// Format a response code as Python's `{rc:#x}` does: `0x2001` lowercase, no padding.
public func formatRc(_ rc: Int) -> String {
    "0x" + String(rc, radix: 16)
}

/// Format a written value the way Python's `!r` would.
public func formatValue(_ value: PTPPropertyValue) -> String {
    switch value {
    case .int(let v): return String(v)
    case .string(let s): return "'\(s)'"
    }
}
