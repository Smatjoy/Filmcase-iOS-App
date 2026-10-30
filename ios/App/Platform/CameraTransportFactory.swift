// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// The ONE place a camera transport is chosen. P5 replaces the `.usb` branch with the
/// ImageCaptureCore adapter (`ICCameraTransport`); nothing else needs to change.
func makeCameraTransport(mode: AppEnvironment.CameraMode, config: ClientConfig) -> any CameraTransport {
    switch mode {
    case .demo:
        DemoCameraTransport(encodings: config.encodings)
    case .usb:
        // SWAP-IN POINT (P5): return ICCameraTransport(...) here.
        UnavailableUSBTransport()
    }
}

/// Stands in for the USB transport until P5. A camera "appears" as soon as the connection
/// listens, and opening a session fails with a message the Camera tab shows.
final class UnavailableUSBTransport: CameraTransport {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        continuation.yield(.deviceAdded(name: "Camera"))
    }

    var authorizationStatus: CameraAuthorizationStatus {
        get async { .authorized }
    }

    func requestAuthorization() async -> Bool { true }

    func openSession() async throws -> any PTPDevice {
        throw CameraConnectionError("USB transport arrives in P5")
    }

    func closeSession() async {}
}
