// Mirrors: the PTPDevice Protocol in src/domain/camera/ptp_device.py and the CameraDevice
// typedef in src/interfaces/static/js/camera/vendor/ptp_device.js.
//
// Two contracts carry over and are easy to get wrong:
//   - the set* methods RETURN a response code, 0 for success. They do not throw on rejection.
//     Turning a non-zero rc into a CameraWriteError is the operations layer's job.
//   - a transport failure, by contrast, throws CameraConnectionError.

import Foundation

/// The operations the domain layer needs from a camera.
public protocol PTPDevice: Sendable {
    /// The model reported by the connected device (empty when unknown).
    var cameraName: String { get }

    /// JS `getPropertyInt`.
    func getInt(_ code: UInt16) async throws -> Int
    /// JS `getPropertyString`.
    func getString(_ code: UInt16) async throws -> String
    /// JS `setPropertyInt`: int32 on the wire. Returns the response code.
    func setInt(_ code: UInt16, _ value: Int) async throws -> Int
    /// JS `setPropertyUint16`: two bytes on the wire (the slot cursor). Returns the response code.
    func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int
    /// JS `setPropertyString`. Returns the response code.
    func setString(_ code: UInt16, _ value: String) async throws -> Int
}

/// A device whose session the caller opens and releases (JS `connect` / `disconnect`).
/// On iOS ImageCaptureCore owns the session, so the later transport implements this.
public protocol ConnectableCameraDevice: PTPDevice {
    func connect() async throws
    func disconnect() async
}
