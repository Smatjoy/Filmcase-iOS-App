// Mirrors: src/application/usecases/camera/get_camera_slots.py and
// src/interfaces/static/js/camera/application/usecases/get_camera_slots.js.
//
// Resolves the per-model strategy and delegates the read to it. The device is passed in
// already connected (on iOS, ImageCaptureCore owns the session).

import Foundation

/// Read every custom slot the camera model offers. Returns an empty list for a model with no
/// custom slots, or one the server does not know: offering slots that may not exist would
/// invite a write into nothing.
public func getCameraSlots(_ device: some PTPDevice, runtime: CameraRuntime) async throws -> [SlotState] {
    let strategy = getStrategy(cameraName: device.cameraName)
    let slotCount = customSlotCount(cameraName: device.cameraName, encodings: runtime.config.encodings)
    return try await strategy.readSlots(device, slotCount: slotCount, runtime: runtime)
}
