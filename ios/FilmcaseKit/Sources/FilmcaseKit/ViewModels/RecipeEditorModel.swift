// Creating and editing a recipe: the form's choices come from the server, and the rules of
// which fields apply follow the browser's form (`CreateRecipe.clean`), which still has the
// last word when saving. A recipe with images keeps its settings; to change them, the
// person saves a new version instead.

import Foundation
import Observation

@MainActor
@Observable
public final class RecipeEditorModel {
    public enum Mode: Equatable, Sendable {
        case create
        case edit(id: Int)
    }

    public private(set) var state: ContentState = .loading
    public private(set) var options: RecipeFormOptions?
    public var draft = RecipeDraft()
    /// False for a recipe with images: only the name and description can change.
    public private(set) var settingsEditable = true
    public private(set) var canSaveAsVersion = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    /// Set when a save went through: the recipe to show.
    public private(set) var savedRecipeID: Int?

    public let mode: Mode

    @ObservationIgnored private let client: FilmcaseClient
    /// The recipe as it loaded, to tell whether a locked recipe's settings were touched.
    @ObservationIgnored private var loaded: RecipeDraft?

    public init(mode: Mode, client: FilmcaseClient) {
        self.mode = mode
        self.client = client
    }

    public var title: String {
        mode == .create ? "New recipe" : "Edit recipe"
    }

    public var lockedNotice: String? {
        settingsEditable
            ? nil
            : "This recipe has images, so its settings stay as they are. You can change the name and description"
                + (canSaveAsVersion ? ", or save your changes as a new version." : ".")
    }

    // --- which fields apply ---

    public var showsDynamicRange: Bool { draft.dRangePriority == "Off" }
    public var showsGrainSize: Bool { draft.grainRoughness != "Off" }
    public var showsKelvin: Bool { draft.whiteBalance == "Kelvin" }
    public var showsMonochromeToning: Bool {
        options?.monochromaticFilmSimulations.contains(draft.filmSimulation) == true
    }

    public func choices(_ field: String) -> [String] { options?.choices[field] ?? [] }

    /// White balances to pick from, with the recipe's own first if the form has no such
    /// choice: one read from a photo ("Daylight Fluorescent") must still show.
    public var whiteBalances: [String] {
        let offered = choices("white_balance")
        return offered.contains(draft.whiteBalance) ? offered : [draft.whiteBalance] + offered
    }

    /// The grain sizes that apply; "Off" is what roughness Off means, not a size to pick.
    public var grainSizes: [String] { choices("grain_size").filter { $0 != "Off" } }

    public func range(_ field: String, fallback: RecipeFieldRange) -> RecipeFieldRange {
        options?.ranges[field] ?? fallback
    }

    /// True when a recipe with images has settings that differ from what it loaded with.
    /// They cannot be saved onto it, only as a new version.
    public var hasUnsavableSettings: Bool {
        guard !settingsEditable, var original = loaded else { return false }
        original.name = draft.name
        original.description = draft.description
        return original != draft
    }

    /// Why the form cannot be written at all; nil when it can.
    public var saveBlockedReason: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the recipe a name." }
        if showsKelvin, draft.kelvinTemperature == nil { return "Enter the white balance temperature." }
        return nil
    }

    private var canWrite: Bool { state == .loaded && saveBlockedReason == nil && !isSaving }

    /// The Save button: never on when it would drop setting changes.
    public var canSave: Bool { canWrite && !hasUnsavableSettings }

    public var canSaveNewVersion: Bool { canWrite && canSaveAsVersion && hasUnsavableSettings }

    // --- intents ---

    public func load() async {
        state = .loading
        do {
            options = try await client.recipeFormOptions()
            if case .edit(let id) = mode {
                let form = try await client.recipeForm(id: id)
                draft = form.values
                loaded = form.values
                settingsEditable = form.isEditable
                canSaveAsVersion = form.hasVersionLine
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .failure(error)
        }
    }

    public func clearError() { errorMessage = nil }

    public func save() async {
        await write { [self] in
            let draft = normalized
            switch mode {
            case .create:
                return try await client.createRecipe(draft)
            case .edit(let id) where settingsEditable:
                try await client.updateRecipe(id: id, draft)
                return id
            case .edit(let id):
                try await client.updateRecipe(id: id, labels: RecipeLabels(name: draft.name, description: draft.description))
                return id
            }
        }
    }

    /// Save the changes as a new version of the recipe, leaving it as it is.
    public func saveAsNewVersion() async {
        guard case .edit(let id) = mode else { return }
        await write { [self] in try await client.createRecipeVersion(of: id, normalized) }
    }

    private func write(_ operation: @escaping () async throws -> Int) async {
        guard canWrite else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            savedRecipeID = try await operation()
        } catch is CancellationError {
            return
        } catch FilmcaseClientError.badRequest(let message) {
            errorMessage = message
        } catch {
            errorMessage = UserMessages.text(for: error)
        }
    }

    /// The draft as the server's form expects it, with what does not apply cleared.
    private var normalized: RecipeDraft {
        var draft = draft
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !showsDynamicRange { draft.dynamicRange = nil }
        if !showsGrainSize { draft.grainSize = "Off" }
        if !showsKelvin { draft.kelvinTemperature = nil }
        if !showsMonochromeToning {
            draft.monochromaticColorWarmCool = nil
            draft.monochromaticColorMagentaGreen = nil
        }
        return draft
    }
}
