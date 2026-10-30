// Mirrors: withCamera in src/interfaces/static/js/camera/interfaces/send_to_camera.js
// (connect, run the work, always disconnect). The later ImageCaptureCore transport supplies
// the ConnectableCameraDevice; obtaining the device (the JS device picker) is its concern.

import Foundation

/// Run `work` against a freshly connected camera, and always release it, even on failure:
/// a camera left claimed cannot be picked up by the next attempt.
public func withCamera<D: ConnectableCameraDevice, T: Sendable>(
    _ device: D, work: (D) async throws -> T
) async throws -> T {
    try await device.connect()
    let result: T
    do {
        result = try await work(device)
    } catch {
        await device.disconnect()
        throw error
    }
    await device.disconnect()
    return result
}
