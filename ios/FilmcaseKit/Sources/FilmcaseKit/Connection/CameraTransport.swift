// What the ImageCaptureCore adapter (P5) implements, and nothing more. The adapter translates
// framework callbacks into these calls and events; every decision (when to open, when to
// recover, what to retry) lives in CameraConnection, which is tested on Linux with
// FakeCameraTransport. See "Adapters carry no decisions" in docs/ios_app_plan.md.

import Foundation

/// Whether the app may talk to the camera (on iOS, the system camera-access prompt).
public enum CameraAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
}

/// What the platform reported about the camera, in the order it happened.
public enum TransportEvent: Equatable, Sendable {
    /// A camera is attached. The stream reports a camera that is already attached when it
    /// is first iterated, so a camera plugged in before the app asked is not missed.
    case deviceAdded(name: String)
    /// The camera was unplugged or switched off.
    case deviceRemoved
    /// The platform closed the session (the camera or the OS ended it).
    case sessionClosed
    /// The platform reported a failure outside any call.
    case error(String)
}

/// The platform side of a camera connection.
public protocol CameraTransport: Sendable {
    var authorizationStatus: CameraAuthorizationStatus { get async }

    /// Ask the person for access. Returns whether it was granted.
    func requestAuthorization() async -> Bool

    /// Platform events. A single consumer: `CameraConnection` iterates it once.
    var events: AsyncStream<TransportEvent> { get }

    /// Open a PTP session with the attached camera.
    /// - Throws: `CameraConnectionError` when there is no camera or the session cannot open.
    func openSession() async throws -> any PTPDevice

    /// Close the session. Safe to call when none is open.
    func closeSession() async
}
