// Mirrors: the error cases raised in src/domain/camera/ptp_usb_device.py
// (ptp_device.CameraConnectionError for short responses, struct.error for
// truncated payloads) and the JS CameraConnectionError.

import Foundation

/// Errors thrown by the PTP framing layer where the Python raises.
public enum PTPError: Error, Equatable, Sendable {
    /// `_parse_response` got fewer than 12 bytes; the camera may have disconnected.
    case responseTooShort(byteCount: Int)
    /// A read ran past the end of the buffer (Python `struct.error`).
    case truncated(offset: Int, needed: Int, available: Int)
    /// A PTP string longer than the one-byte character count can express.
    case stringTooLong(characterCount: Int)
}
