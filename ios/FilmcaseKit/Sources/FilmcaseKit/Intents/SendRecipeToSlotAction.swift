// "Send recipe X to C3" for Siri and Shortcuts. Everything the intent does except asking the
// person: the adapter confirms the overwrite (`overwritePrompt`), then calls `perform`, and
// speaks `outcome.dialog`. The push always goes through SlotBackupWorkflow, which backs the
// slot up first; there is no way to push without a backup here.

import Foundation

public struct SendRecipeOutcome: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        /// Written and read back; the old slot was backed up first.
        case verified
        /// The camera answered but these properties (as the server names them) did not take.
        case partiallyFailed([String])
        case connectionLost
        /// No camera is connected (or it is not in a mode that allows it).
        case noCamera
        /// The camera has no such slot (`slotCount` is 0 for a model with no custom slots).
        case invalidSlot(slot: Int, slotCount: Int)
        /// The recipe has no name, so a slot cannot take it.
        case unnamedRecipe
        case recipeNotFound
        /// The camera cannot take this recipe (nothing was written).
        case invalidRecipe(String)
        /// The server could not be reached or answered something unreadable.
        case serverUnavailable(String)
        /// Refused or failed before anything was written (for instance the backup could not be stored).
        case failed(String)
        case cancelled
    }

    public let recipeID: Int
    /// The recipe's name, once it is known.
    public let recipeName: String?
    public let slot: Int
    public let result: Result
    /// The sentence for Siri or the Shortcuts result.
    public let dialog: String

    /// True only for a verified push.
    public var succeeded: Bool { result == .verified }
}

public struct SendRecipeToSlotAction: Sendable {
    private let client: FilmcaseClient
    private let workflowProvider: @Sendable () async -> SlotBackupWorkflow

    /// A fixed workflow (tests, previews).
    public init(client: FilmcaseClient, workflow: SlotBackupWorkflow) {
        self.client = client
        self.workflowProvider = { workflow }
    }

    /// The production shape: the workflow is built per call from the runtime that is current
    /// then, so a refreshed config is used (but never changes halfway through a push).
    public init(
        client: FilmcaseClient, runner: any CameraOperationRunner, store: any BackupStore,
        runtimeSource: any CameraRuntimeSource, clock: any FilmcaseClock = SystemClock()
    ) {
        self.client = client
        self.workflowProvider = {
            SlotBackupWorkflow(
                runner: runner, store: store, runtime: await runtimeSource.currentRuntime(), clock: clock)
        }
    }

    /// The question to ask before overwriting, for the intent's confirmation step.
    public static func overwritePrompt(recipeName: String, slot: Int) -> String {
        "Replace C\(slot) with \u{201C}\(recipeName)\u{201D}? What is in C\(slot) now is backed up first."
    }

    /// Check the camera and slot, fetch and validate the recipe, back the slot up, push, verify.
    /// Never throws: every failure is an outcome with its own dialog.
    public func perform(recipeID: Int, slot: Int) async -> SendRecipeOutcome {
        let workflow = await workflowProvider()

        func outcome(_ result: SendRecipeOutcome.Result, name: String? = nil) -> SendRecipeOutcome {
            SendRecipeOutcome(
                recipeID: recipeID, recipeName: name, slot: slot, result: result,
                dialog: Self.dialog(for: result, name: name, slot: slot))
        }

        guard let cameraName = await workflow.runner.cameraName else { return outcome(.noCamera) }
        let slotCount = customSlotCount(cameraName: cameraName, encodings: workflow.runtime.config.encodings)
        guard slotCount > 0, (1...slotCount).contains(slot) else {
            return outcome(.invalidSlot(slot: slot, slotCount: slotCount))
        }

        let detail: RecipeDetail
        do {
            detail = try await client.recipe(id: recipeID)
        } catch is CancellationError {
            return outcome(.cancelled)
        } catch FilmcaseClientError.notFound {
            return outcome(.recipeNotFound)
        } catch {
            return outcome(.serverUnavailable(UserMessages.text(for: error)))
        }
        let name = detail.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if RecipeSendRule.isUnnamed(name) { return outcome(.unnamedRecipe) }

        let recipe: Recipe
        do {
            let data = try await client.cameraPayload(recipeId: recipeID)
            recipe = try JSONDecoder().decode(Recipe.self, from: data)
        } catch is CancellationError {
            return outcome(.cancelled, name: name)
        } catch is DecodingError {
            return outcome(.serverUnavailable(UserMessages.text(for: FilmcaseClientError.decoding(""))), name: name)
        } catch {
            return outcome(.serverUnavailable(UserMessages.text(for: error)), name: name)
        }

        do {
            switch try await workflow.push(recipe, to: slot) {
            case .verified: return outcome(.verified, name: name)
            case .partiallyFailed(let failed): return outcome(.partiallyFailed(failed), name: name)
            case .connectionLost: return outcome(.connectionLost, name: name)
            }
        } catch is CancellationError {
            return outcome(.cancelled, name: name)
        } catch SlotBackupError.slotOutOfRange(let bad, let count) {
            return outcome(.invalidSlot(slot: bad, slotCount: count), name: name)
        } catch let error as RecipeValidationError {
            return outcome(.invalidRecipe(UserMessages.text(for: error)), name: name)
        } catch let error as RecipeConversionError {
            return outcome(.invalidRecipe(UserMessages.text(for: error)), name: name)
        } catch {
            return outcome(.failed(UserMessages.text(for: error)), name: name)
        }
    }

    static let noCameraDialog =
        "No camera is connected. Connect your camera with a USB-C cable in USB RAW CONV./BACKUP RESTORE mode."

    static func dialog(for result: SendRecipeOutcome.Result, name: String?, slot: Int) -> String {
        let quoted = name.map { "\u{201C}\($0)\u{201D}" } ?? "the recipe"
        switch result {
        case .verified:
            return "Sent \(quoted) to C\(slot) and checked it. The old C\(slot) was backed up first."
        case .partiallyFailed(let failed):
            let list = failed.map(UserMessages.propertyLabel).joined(separator: ", ")
            return "C\(slot) took \(quoted) only in part. These settings were not applied: \(list). "
                + "The old C\(slot) was backed up first."
        case .connectionLost:
            return "The camera connection was lost while sending \(quoted) to C\(slot). "
                + "Check the cable and look at C\(slot) before trying again."
        case .noCamera:
            return noCameraDialog
        case .invalidSlot(let bad, let count):
            return UserMessages.text(for: SlotBackupError.slotOutOfRange(slot: bad, slotCount: count))
        case .unnamedRecipe:
            return RecipeSendRule.unnamedReason
        case .recipeNotFound:
            return "Filmcase could not find that recipe."
        case .invalidRecipe(let reason):
            return "\(reason) Nothing was sent."
        case .serverUnavailable(let reason):
            return "\(reason) Nothing was sent."
        case .failed(let reason):
            return "\(reason) Nothing was sent."
        case .cancelled:
            return "Cancelled. Nothing was sent."
        }
    }
}
