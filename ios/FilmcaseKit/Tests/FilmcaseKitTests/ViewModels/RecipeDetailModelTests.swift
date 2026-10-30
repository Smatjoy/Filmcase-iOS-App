import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

private func detailDecoded(_ overrides: [String: Any] = [:]) throws -> RecipeDetail {
    var object = jsonObject(fixture: "recipe_detail")
    for (key, value) in overrides { object[key] = value }
    return try JSONDecoder().decode(RecipeDetail.self, from: json(object))
}

private func rows(_ sections: [SpecSection], _ title: String) -> [String] {
    sections.first { $0.title == title }?.rows.map { "\($0.label)=\($0.value)" } ?? []
}

@Suite("SpecSheet")
struct SpecSheetTests {
    @Test func theFixtureRecipeReadsLikeTheWebDetailPage() throws {
        let sections = SpecSheet.sections(for: try detailDecoded())
        #expect(sections.map(\.title) == [
            "Basic", "Dynamic Range", "Grain", "White Balance", "Color Chrome", "Tone & Color", "Detail", "Camera",
        ])
        #expect(rows(sections, "Basic") == ["Name=Kodak Portra", "Film Simulation=Classic Chrome"])
        #expect(rows(sections, "Dynamic Range") == ["Dynamic Range=DR200", "D-Range Priority=Off"])
        #expect(rows(sections, "Grain") == ["Grain Roughness=Weak", "Grain Size=Small"])
        #expect(rows(sections, "White Balance") == ["White Balance=Daylight", "Red=0", "Blue=0"])
        #expect(rows(sections, "Color Chrome") == ["Color Chrome Effect=Strong", "Color Chrome FX Blue=Off"])
        #expect(rows(sections, "Tone & Color") == ["Highlight=-1", "Shadow=+1", "Color=+2"])
        #expect(rows(sections, "Detail") == ["Sharpness=0", "High ISO NR=0", "Clarity=0"])
        #expect(rows(sections, "Camera").first == "Sensors=X-Trans V")
    }

    @Test func halfStepsAndSignsAreFormattedLikeTheWeb() throws {
        let sections = SpecSheet.sections(for: try detailDecoded([
            "highlight": 1.5, "shadow": -0.5, "color": 0.0, "sharpness": 3.0, "white_balance_red": 4,
            "white_balance_blue": -3,
        ]))
        #expect(rows(sections, "Tone & Color") == ["Highlight=+1.5", "Shadow=-0.5", "Color=0"])
        #expect(rows(sections, "Detail").first == "Sharpness=+3")
        #expect(rows(sections, "White Balance") == ["White Balance=Daylight", "Red=+4", "Blue=-3"])
    }

    @Test func settingsThatAreNotSetAreLeftOut() throws {
        let sections = SpecSheet.sections(for: try detailDecoded([
            "highlight": NSNull(), "shadow": NSNull(), "color": NSNull(),
            "sharpness": NSNull(), "high_iso_nr": NSNull(), "clarity": NSNull(),
            "sensors": [String](), "bodies": [String](),
        ]))
        #expect(!sections.map(\.title).contains("Tone & Color"))
        #expect(!sections.map(\.title).contains("Detail"))
        #expect(!sections.map(\.title).contains("Camera"))
    }

    @Test func grainSizeOnlyAppliesWhenGrainIsOn() throws {
        let off = SpecSheet.sections(for: try detailDecoded(["grain_roughness": "Off", "grain_size": "Off"]))
        #expect(rows(off, "Grain") == ["Grain Roughness=Off"])
    }

    @Test func blackAndWhiteToneOnlyAppearsForMonochromeRecipes() throws {
        let colour = SpecSheet.sections(for: try detailDecoded())
        #expect(!colour.map(\.title).contains("BW Tone"))

        let mono = SpecSheet.sections(for: try detailDecoded([
            "is_monochromatic": true, "monochromatic_color_warm_cool": 2.0,
            "monochromatic_color_magenta_green": -1.0,
        ]))
        #expect(rows(mono, "BW Tone") == ["BW Warm / Cool=+2", "BW Magenta / Green=-1"])
    }

    @Test(arguments: [(0, "0"), (3, "+3"), (-2, "-2")])
    func integersCarryAnExplicitSign(value: Int, text: String) {
        #expect(SpecSheet.signed(value) == text)
    }

    @Test func sensorsAndBodiesAreJoined() throws {
        let sections = SpecSheet.sections(for: try detailDecoded(["sensors": ["X-Trans IV", "X-Trans V"]]))
        #expect(rows(sections, "Camera").first == "Sensors=X-Trans IV, X-Trans V")
    }
}

@MainActor
@Suite("RecipeDetailModel")
struct RecipeDetailModelTests {
    private func rig(
        payload: [String: Any]? = nil, payloadStatus: Int = 200, detailStatus: Int = 200
    ) -> ModelRig {
        let payloadBody = payload.map(json) ?? Fixture.data("camera_payload")
        return ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            let path = request.url?.path ?? ""
            if path.hasSuffix("camera-payload.json") { return reply(payloadBody, status: payloadStatus) }
            return detailStatus == 200 ? .fixture("recipe_detail") : .fixture("error_404", status: detailStatus)
        })
    }

    private func xt50() -> ConnectedCamera {
        ConnectedCamera(name: "X-T50", encodings: TestSupport.encodings)
    }

    private func payload(_ overrides: [String: Any]) -> [String: Any] {
        var object = jsonObject(fixture: "camera_payload")
        for (key, value) in overrides { object[key] = value }
        return object
    }

    @Test func loadsTheDetailAndBuildsTheSpecSheet() async {
        let rig = rig()
        let model = RecipeDetailModel(recipeID: 1, client: rig.client)
        #expect(model.state == .loading)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.detail?.name == "Kodak Portra")
        #expect(model.specSections.first?.title == "Basic")
        #expect(model.cameraRecipe?.name == "Kodak Portra")
    }

    @Test func theDescriptionTextIsNilUntilThereIsOneToShow() async {
        var object = jsonObject(fixture: "recipe_detail")
        object["description"] = "  Warm, soft skin tones.\n"
        let body = json(object)
        let rig = ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            let path = request.url?.path ?? ""
            return path.hasSuffix("camera-payload.json") ? .fixture("camera_payload") : reply(body)
        })
        let model = RecipeDetailModel(recipeID: 1, client: rig.client)
        #expect(model.descriptionText == nil)
        await model.load()
        #expect(model.descriptionText == "Warm, soft skin tones.")
    }

    @Test(arguments: ["", "   ", "\n\t "])
    func aBlankDescriptionIsNil(blank: String) async {
        var object = jsonObject(fixture: "recipe_detail")
        object["description"] = blank
        let body = json(object)
        let rig = ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            let path = request.url?.path ?? ""
            return path.hasSuffix("camera-payload.json") ? .fixture("camera_payload") : reply(body)
        })
        let model = RecipeDetailModel(recipeID: 1, client: rig.client)
        await model.load()
        #expect(model.state == .loaded)
        #expect(model.descriptionText == nil)
    }

    @Test func aMissingRecipeIsAnError() async {
        let model = RecipeDetailModel(recipeID: 9, client: rig(detailStatus: 404).client)
        await model.load()
        #expect(model.state == .error("The server could not find that."))
        #expect(model.detail == nil)
        #expect(!model.canSendToCamera)
    }

    @Test func noServerIsOffline() async {
        let rig = ModelRig(script: { _ in .transportError() })
        let model = RecipeDetailModel(recipeID: 1, client: rig.client)
        await model.load()
        #expect(model.state == .offline)
    }

    @Test func aNamedRecipeCanBeSentWhenNoCameraIsConnectedYet() async {
        let model = RecipeDetailModel(recipeID: 1, client: rig().client, camera: MutableCameraSource())
        await model.load()
        #expect(model.canSendToCamera)
        #expect(model.sendBlockedReason == nil)
    }

    @Test func aRecipeWithoutANameCannotBeSent() async {
        let model = RecipeDetailModel(recipeID: 1, client: rig(payload: payload(["name": "  "])).client)
        await model.load()
        #expect(model.state == .loaded)
        #expect(!model.canSendToCamera)
        #expect(model.sendBlockedReason == "Name this recipe before sending it to a camera.")
    }

    @Test func aRecipeTheConnectedCameraCanTakeCanBeSent() async {
        let source = MutableCameraSource(xt50())
        let model = RecipeDetailModel(recipeID: 1, client: rig().client, camera: source)
        await model.load()
        #expect(model.canSendToCamera)
    }

    @Test func aRecipeTheConnectedCameraCannotTakeIsBlockedWithTheReason() async {
        let source = MutableCameraSource(xt50())
        let model = RecipeDetailModel(
            recipeID: 1, client: rig(payload: payload(["film_simulation": "Not A Film"])).client, camera: source)
        await model.load()
        #expect(!model.canSendToCamera)
        #expect(model.sendBlockedReason?.contains("film_simulation") == true)
    }

    @Test func aCameraWithoutCustomSlotsBlocksSending() async {
        let source = MutableCameraSource(ConnectedCamera(name: "X-T100", encodings: TestSupport.encodings))
        let model = RecipeDetailModel(recipeID: 1, client: rig().client, camera: source)
        await model.load()
        #expect(!model.canSendToCamera)
        #expect(model.sendBlockedReason == "X-T100 has no custom slots.")
    }

    @Test func connectingACameraLaterChangesTheAnswer() async {
        let source = MutableCameraSource()
        let model = RecipeDetailModel(
            recipeID: 1, client: rig(payload: payload(["white_balance": "Not A Balance"])).client, camera: source)
        await model.load()
        #expect(model.canSendToCamera, "nothing to check it against yet")

        source.set(xt50())
        await model.recheckCamera()
        #expect(!model.canSendToCamera)

        source.set(nil)
        await model.recheckCamera()
        #expect(model.canSendToCamera)
    }

    @Test func unreadableCameraDataKeepsTheDetailButBlocksSending() async {
        let model = RecipeDetailModel(recipeID: 1, client: rig(payloadStatus: 404).client)
        await model.load()
        #expect(model.state == .loaded)
        #expect(!model.canSendToCamera)
        #expect(model.sendBlockedReason == "The camera data for this recipe could not be loaded.")
    }
}
