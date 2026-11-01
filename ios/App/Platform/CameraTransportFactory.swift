// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// The ONE place a camera transport is chosen.
@MainActor
func makeCameraTransport(mode: AppEnvironment.CameraMode, config: ClientConfig) -> any CameraTransport {
    switch mode {
    case .demo:
        DemoCameraTransport(encodings: config.encodings)
    case .usb:
        ICCameraTransport()
    }
}
