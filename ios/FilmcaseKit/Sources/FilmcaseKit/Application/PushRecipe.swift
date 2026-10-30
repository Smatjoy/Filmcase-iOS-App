// Mirrors: src/application/usecases/camera/push_recipe.py and
// src/interfaces/static/js/camera/application/usecases/push_recipe.js (pushRecipeToCamera).
//
// Resolves the per-model strategy and delegates the write to it. The device is passed in
// already connected; releasing it is the caller's job (see withCamera).

import Foundation

/// Write a recipe to a custom slot (1-based `slotIndex`).
/// - Throws: validation errors, `CameraConnectionError`, `RecipeWriteError`.
public func pushRecipeToCamera(
    _ device: some PTPDevice, recipe: Recipe, slotIndex: Int, runtime: CameraRuntime
) async throws {
    let strategy = getStrategy(cameraName: device.cameraName)
    try await strategy.pushRecipe(device, recipe: recipe, slotIndex: slotIndex, runtime: runtime)
}
