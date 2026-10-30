// One recipe: its detail, the spec sheet to show, and whether it can be sent to a camera.

import Foundation
import Observation

@MainActor
@Observable
public final class RecipeDetailModel {
    public let recipeID: Int
    public private(set) var state: ContentState = .loading
    public private(set) var detail: RecipeDetail?
    public private(set) var specSections: [SpecSection] = []
    /// The recipe in the shape the camera write path takes (the camera payload).
    public private(set) var cameraRecipe: Recipe?
    public private(set) var canSendToCamera = false
    /// Why it cannot be sent, for a hint under the disabled button.
    public private(set) var sendBlockedReason: String?

    @ObservationIgnored private let client: FilmcaseClient
    @ObservationIgnored private let camera: (any ConnectedCameraSource)?
    @ObservationIgnored private var payloadError: String?

    public init(recipeID: Int, client: FilmcaseClient, camera: (any ConnectedCameraSource)? = nil) {
        self.recipeID = recipeID
        self.client = client
        self.camera = camera
    }

    /// Load the detail (and, once it is on screen, the camera payload).
    public func load() async {
        if detail == nil { state = .loading }
        do {
            let loaded = try await client.recipe(id: recipeID)
            detail = loaded
            specSections = SpecSheet.sections(for: loaded)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            if detail == nil { state = .failure(error) }
            return
        }
        await loadCameraRecipe()
    }

    /// The camera was connected or disconnected: judge the recipe against it again.
    public func recheckCamera() async {
        await evaluateSending()
    }

    private func loadCameraRecipe() async {
        do {
            let data = try await client.cameraPayload(recipeId: recipeID)
            cameraRecipe = try JSONDecoder().decode(Recipe.self, from: data)
            payloadError = nil
        } catch is CancellationError {
            return
        } catch {
            cameraRecipe = nil
            payloadError = "The camera data for this recipe could not be loaded."
        }
        await evaluateSending()
    }

    private func evaluateSending() async {
        guard let recipe = cameraRecipe else {
            block(payloadError ?? "The camera data for this recipe is not loaded yet.")
            return
        }
        if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block("Name this recipe before sending it to a camera.")
            return
        }
        guard let connected = await camera?.connectedCamera() else {
            canSendToCamera = true
            sendBlockedReason = nil
            return
        }
        if customSlotCount(cameraName: connected.name, encodings: connected.encodings) == 0 {
            block("\(connected.name) has no custom slots.")
            return
        }
        do {
            try validateRecipeForProfile(
                recipe, profile: getProfile(cameraName: connected.name, encodings: connected.encodings))
            canSendToCamera = true
            sendBlockedReason = nil
        } catch {
            block(UserMessages.text(for: error))
        }
    }

    private func block(_ reason: String) {
        canSendToCamera = false
        sendBlockedReason = reason
    }
}
