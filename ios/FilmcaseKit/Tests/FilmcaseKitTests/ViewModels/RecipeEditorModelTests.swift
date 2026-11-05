import Foundation
import Synchronization
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

@MainActor
@Suite("RecipeEditorModel")
struct RecipeEditorModelTests {
    /// Serves the recorded form; *writes* answers every POST.
    private func rig(
        editable: Bool = true, versionLine: Bool = true,
        writes: @escaping @Sendable (URLRequest) -> StubReply = { _ in reply(json(["id": 42]), status: 201) }
    ) -> ModelRig {
        ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            if request.httpMethod == "POST" { return writes(request) }
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("form-options/") { return .fixture("recipe_form_options") }
            var form = jsonObject(fixture: "recipe_form")
            form["is_editable"] = editable
            form["has_version_line"] = versionLine
            return reply(json(form))
        })
    }

    private func written(_ rig: ModelRig) -> URLRequest? {
        rig.transport.requests.first { $0.httpMethod == "POST" }
    }

    @Test func choicesComeFromTheServer() async {
        let model = RecipeEditorModel(mode: .create, client: rig().client)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.title == "New recipe")
        #expect(model.choices("film_simulation").contains("Classic Negative"))
        #expect(model.grainSizes == ["Small", "Large"])
        #expect(model.range("highlight", fallback: RecipeFieldRange(min: 0, max: 0, step: 1)).step == 0.5)
    }

    @Test func aWhiteBalanceFromAPhotoStaysPickable() async {
        let model = RecipeEditorModel(mode: .create, client: rig().client)
        await model.load()
        #expect(model.whiteBalances == model.choices("white_balance"))

        model.draft.whiteBalance = "Daylight Fluorescent"
        #expect(model.whiteBalances.first == "Daylight Fluorescent")
        #expect(model.whiteBalances.count == model.choices("white_balance").count + 1)
    }

    @Test func fieldsAppearOnlyWhenTheyApply() async {
        let model = RecipeEditorModel(mode: .create, client: rig().client)
        await model.load()
        #expect(model.showsDynamicRange)
        #expect(!model.showsGrainSize)
        #expect(!model.showsKelvin)
        #expect(!model.showsMonochromeToning)

        model.draft.dRangePriority = "Strong"
        model.draft.grainRoughness = "Weak"
        model.draft.whiteBalance = "Kelvin"
        model.draft.filmSimulation = "Acros STD"
        #expect(!model.showsDynamicRange)
        #expect(model.showsGrainSize)
        #expect(model.showsKelvin)
        #expect(model.showsMonochromeToning)
    }

    @Test func aNameAndAKelvinTemperatureAreNeededToSave() async {
        let model = RecipeEditorModel(mode: .create, client: rig().client)
        await model.load()
        #expect(model.saveBlockedReason == "Give the recipe a name.")
        #expect(!model.canSave)

        model.draft.name = "Gold"
        #expect(model.canSave)

        model.draft.whiteBalance = "Kelvin"
        #expect(model.saveBlockedReason == "Enter the white balance temperature.")
        model.draft.kelvinTemperature = 6500
        #expect(model.canSave)
    }

    @Test func creatingSendsTheFormAndClearsWhatDoesNotApply() async throws {
        let rig = rig()
        let model = RecipeEditorModel(mode: .create, client: rig.client)
        await model.load()
        model.draft.name = "  Gold "
        model.draft.dRangePriority = "Weak"
        model.draft.grainSize = "Large"
        model.draft.kelvinTemperature = 6500
        model.draft.monochromaticColorWarmCool = 3

        await model.save()

        #expect(model.savedRecipeID == 42)
        let sent = try #require(written(rig))
        #expect(sent.url?.absoluteString.hasSuffix("/api/v1/recipes/") == true)
        let form = body(sent)
        #expect(form["name"] as? String == "Gold")
        #expect(form["grain_size"] as? String == "Off")
        #expect(form["dynamic_range"] == nil)
        #expect(form["kelvin_temperature"] == nil)
        #expect(form["monochromatic_color_warm_cool"] == nil)
    }

    @Test func editingLoadsTheRecipeAndSavesEverything() async throws {
        let rig = rig(writes: { _ in reply(json(["id": 1])) })
        let model = RecipeEditorModel(mode: .edit(id: 1), client: rig.client)
        await model.load()
        #expect(model.title == "Edit recipe")
        #expect(model.draft.name == "Kodak Gold")
        #expect(model.settingsEditable)
        #expect(model.lockedNotice == nil)

        model.draft.color = -2
        await model.save()

        #expect(model.savedRecipeID == 1)
        let sent = try #require(written(rig))
        #expect(body(sent)["color"] as? Int == -2)
    }

    @Test func aRecipeWithImagesSendsOnlyItsNameAndDescription() async throws {
        let rig = rig(editable: false, writes: { _ in reply(json(["id": 1])) })
        let model = RecipeEditorModel(mode: .edit(id: 1), client: rig.client)
        await model.load()
        #expect(!model.settingsEditable)
        #expect(model.lockedNotice?.contains("new version") == true)

        model.draft.description = "Warm"
        await model.save()

        let form = body(try #require(written(rig)))
        #expect(Set(form.keys) == ["name", "description"])
    }

    @Test func aLockedRecipesChangedSettingsCanOnlyGoToANewVersion() async {
        let model = RecipeEditorModel(mode: .edit(id: 1), client: rig(editable: false).client)
        await model.load()
        model.draft.description = "Warm"
        #expect(model.canSave)
        #expect(!model.canSaveNewVersion)

        model.draft.color = 3
        #expect(model.hasUnsavableSettings)
        #expect(!model.canSave)
        #expect(model.canSaveNewVersion)

        model.draft.color = nil
        #expect(model.canSave)
    }

    @Test func noVersionLineMeansNoVersionOffer() async {
        let model = RecipeEditorModel(mode: .edit(id: 1), client: rig(editable: false, versionLine: false).client)
        await model.load()
        #expect(model.lockedNotice?.contains("new version") == false)
    }

    @Test func aNewVersionGoesToTheVersionsRoute() async throws {
        let rig = rig(editable: false)
        let model = RecipeEditorModel(mode: .edit(id: 1), client: rig.client)
        await model.load()
        model.draft.color = 3

        await model.saveAsNewVersion()

        #expect(model.savedRecipeID == 42)
        let sent = try #require(written(rig))
        #expect(sent.url?.absoluteString.hasSuffix("/recipes/1/versions/") == true)
        #expect(body(sent)["color"] as? Int == 3)
    }

    @Test func wholeNumbersSentWithADecimalPointDecode() throws {
        // The server stores some of these as decimals: `"color": -2.0`.
        var text = String(decoding: Fixture.data("recipe_form"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"color\": null", with: "\"color\": -2.0")
        let form = try JSONDecoder().decode(RecipeFormValues.self, from: Data(text.utf8))
        #expect(form.values.color == -2)
    }

    @Test func aRefusalShowsTheServersWords() async {
        let rig = rig(writes: { _ in reply(json(["error": "Clarity: Ensure this value is less than or equal to 5."]), status: 400) })
        let model = RecipeEditorModel(mode: .create, client: rig.client)
        await model.load()
        model.draft.name = "Gold"

        await model.save()

        #expect(model.errorMessage == "Clarity: Ensure this value is less than or equal to 5.")
        #expect(model.savedRecipeID == nil)
        model.clearError()
        #expect(model.errorMessage == nil)
    }
}
