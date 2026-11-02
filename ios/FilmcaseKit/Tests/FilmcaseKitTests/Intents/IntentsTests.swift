import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

private func summary(
    _ id: Int, name: String? = nil, favorite: Bool = false, images: Int = 0
) -> [String: Any] {
    var object = summaryJSON(id: id)
    object["name"] = name ?? "Recipe \(id)"
    object["is_favorite"] = favorite
    object["image_count"] = images
    return object
}

private func page(_ results: [[String: Any]]) -> Data {
    json([
        "count": results.count, "next": NSNull(), "previous": NSNull(),
        "results": results, "facets": [String: Any](),
    ] as [String: Any])
}

@Suite("RecipeLookup")
struct RecipeLookupTests {
    private func lookup(
        favourites: [[String: Any]] = [], all: [[String: Any]] = [], detailStatus: Int = 200
    ) -> (RecipeLookup, ModelRig) {
        let favouritesBody = page(favourites)
        let allBody = page(all)
        let rig = ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            let path = request.url?.path ?? ""
            if path.hasPrefix("/api/v1/recipes/") && path != "/api/v1/recipes/" {
                return detailStatus == 200
                    ? .fixture("recipe_detail") : .fixture("error_404", status: detailStatus)
            }
            return reply(request.queryValue("favorite") == "true" ? favouritesBody : allBody)
        })
        return (RecipeLookup(client: rig.client), rig)
    }

    @Test func byIDReturnsTheRecipeAndSkipsOnesTheServerDoesNotKnow() async throws {
        let (lookup, _) = lookup()
        let found = try await lookup.recipes(withIDs: [1])
        #expect(found.map(\.name) == ["Kodak Portra"])
        #expect(found.first?.isSendable == true)

        let (missing, _) = self.lookup(detailStatus: 404)
        #expect(try await missing.recipes(withIDs: [1, 2]).isEmpty)
    }

    @Test func byIDKeepsAnUnnamedRecipeButFlagsItUnsendable() async throws {
        var object = jsonObject(fixture: "recipe_detail")
        object["name"] = "  "
        let body = json(object)
        let rig = ModelRig(script: { request in request.isAuthenticated ? reply(body) : .fixture("recipe_list") })
        let found = try await RecipeLookup(client: rig.client).recipes(withIDs: [1])
        #expect(found.count == 1)
        #expect(found.first?.isSendable == false)
    }

    @Test func searchSendsTheNameAndDropsUnnamedRecipes() async throws {
        let (lookup, rig) = lookup(all: [summary(1, name: "Portra"), summary(2, name: " "), summary(3, name: "Portra 800")])
        let found = try await lookup.search(name: " port ")
        #expect(found.map(\.id) == [1, 3])
        #expect(rig.transport.authenticatedRequests.last?.queryValue("name_search") == "port")
    }

    @Test func aBlankSearchGivesTheSuggestions() async throws {
        let (lookup, _) = lookup(favourites: [summary(5, favorite: true)], all: [summary(5), summary(6)])
        #expect(try await lookup.search(name: "  ").map(\.id) == [5, 6])
    }

    @Test func suggestionsAreFavouritesThenMostUsedWithoutRepeats() async throws {
        let (lookup, _) = lookup(
            favourites: [summary(1, favorite: true, images: 2), summary(2, favorite: true, images: 9)],
            all: [summary(1, favorite: true, images: 2), summary(3, images: 1), summary(4, images: 7), summary(5, images: 7)])
        #expect(try await lookup.suggested().map(\.id) == [2, 1, 4, 5, 3])
    }

    @Test func suggestionsLeaveOutUnnamedAndStopAtTwenty() async throws {
        let many = (1...40).map { summary($0, name: $0 == 1 ? "" : "R\($0)", images: $0) }
        let (lookup, _) = lookup(all: many)
        let suggested = try await lookup.suggested()
        #expect(suggested.count == 20)
        #expect(!suggested.contains { $0.id == 1 })
        #expect(suggested.first?.id == 40)
    }

    @Test func fullFavouritesSkipTheSecondRequest() async throws {
        let favourites = (1...25).map { summary($0, favorite: true) }
        let (lookup, rig) = lookup(favourites: favourites)
        #expect(try await lookup.suggested().count == 20)
        #expect(rig.transport.authenticatedRequests.count == 1)
    }

    @Test func theUnnamedRuleReadsLikeTheDetailScreen() async throws {
        var object = jsonObject(fixture: "recipe_detail")
        object["name"] = ""
        let body = json(object)
        let rig = ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            return request.url?.path.hasSuffix("camera-payload.json") == true ? .fixture("camera_payload") : reply(body)
        })
        let model = await RecipeDetailModel(recipeID: 1, client: rig.client)
        await model.load()
        #expect(await model.sendBlockedReason == RecipeSendRule.unnamedReason)
    }
}

@Suite("SendRecipeToSlotAction")
struct SendRecipeToSlotActionTests {
    private func client(
        detail: StubReply = .fixture("recipe_detail"), payload: StubReply = .fixture("camera_payload")
    ) -> ModelRig {
        ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            return request.url?.path.hasSuffix("camera-payload.json") == true ? payload : detail
        })
    }

    @Test func aVerifiedSendBacksUpFirstAndSaysSo() async throws {
        let rig = try await WorkflowRig()
        let action = SendRecipeToSlotAction(client: client().client, workflow: rig.workflow)
        let outcome = await action.perform(recipeID: 1, slot: 3)

        #expect(outcome.result == .verified)
        #expect(outcome.succeeded)
        #expect(outcome.recipeName == "Kodak Portra")
        #expect(outcome.dialog
            == "Sent \u{201C}Kodak Portra\u{201D} to C3 and checked it. The old C3 was backed up first.")
        let backup = try #require(try await rig.store.latest(slot: 3, camera: ConnectionRig.cameraName))
        #expect(backup.slotName == WorkflowRig.originalName)
        #expect(await rig.nameWrites == ["Kodak Portra"])
    }

    @Test func theRuntimeSourceInitBuildsTheSameWorkflow() async throws {
        let rig = try await WorkflowRig()
        let action = SendRecipeToSlotAction(
            client: client().client, runner: rig.rig.connection, store: rig.store,
            runtimeSource: rig.workflow.runtime)
        #expect(await action.perform(recipeID: 1, slot: 1).result == .verified)
        #expect(try await rig.store.all().count == 1)
    }

    @Test func noCameraSaysHowToConnect() async throws {
        let unplugged = try ConnectionRig()
        let workflow = SlotBackupWorkflow(
            runner: unplugged.connection, store: InMemoryBackupStore(),
            runtime: try TestSupport.runtime(unplugged.device))
        let outcome = await SendRecipeToSlotAction(client: client().client, workflow: workflow)
            .perform(recipeID: 1, slot: 1)
        #expect(outcome.result == .noCamera)
        #expect(outcome.dialog.contains("USB-C cable"))
        #expect(outcome.dialog.contains("USB RAW CONV./BACKUP RESTORE"))
        #expect(await unplugged.device.writes.isEmpty)
    }

    @Test(arguments: [0, 8, -1])
    func aSlotOutsideTheCameraIsRefusedBeforeAnythingIsFetched(slot: Int) async throws {
        let rig = try await WorkflowRig()
        let server = client()
        let outcome = await SendRecipeToSlotAction(client: server.client, workflow: rig.workflow)
            .perform(recipeID: 1, slot: slot)
        #expect(outcome.result == .invalidSlot(slot: slot, slotCount: 7))
        #expect(outcome.dialog == "C\(slot) does not exist on this camera (C1 to C7).")
        #expect(server.transport.authenticatedRequests.isEmpty)
        #expect(await rig.device.writes.isEmpty)
    }

    @Test func anUnnamedRecipeIsNotSentAndNotBackedUp() async throws {
        var object = jsonObject(fixture: "recipe_detail")
        object["name"] = " "
        let rig = try await WorkflowRig()
        let server = client(detail: reply(json(object)))
        let outcome = await SendRecipeToSlotAction(client: server.client, workflow: rig.workflow)
            .perform(recipeID: 1, slot: 2)
        #expect(outcome.result == .unnamedRecipe)
        #expect(outcome.dialog == RecipeSendRule.unnamedReason)
        #expect(try await rig.store.all().isEmpty)
        #expect(await rig.device.writes.isEmpty)
    }

    @Test func aMissingRecipeAndAnUnreachableServerHaveTheirOwnDialogs() async throws {
        let rig = try await WorkflowRig()
        let missing = await SendRecipeToSlotAction(
            client: client(detail: .fixture("error_404", status: 404)).client, workflow: rig.workflow
        ).perform(recipeID: 9, slot: 1)
        #expect(missing.result == .recipeNotFound)

        let down = await SendRecipeToSlotAction(
            client: client(detail: .fixture("error_503", status: 503)).client, workflow: rig.workflow
        ).perform(recipeID: 1, slot: 1)
        guard case .serverUnavailable = down.result else { Issue.record("got \(down.result)"); return }
        #expect(down.dialog.hasSuffix("Nothing was sent."))
        #expect(try await rig.store.all().isEmpty)
    }

    @Test func aRecipeTheCameraCannotTakeIsRefusedBeforeTheBackup() async throws {
        var payload = jsonObject(fixture: "camera_payload")
        payload["film_simulation"] = "Not A Simulation"
        let rig = try await WorkflowRig()
        let outcome = await SendRecipeToSlotAction(
            client: client(payload: reply(json(payload))).client, workflow: rig.workflow
        ).perform(recipeID: 1, slot: 1)
        guard case .invalidRecipe = outcome.result else { Issue.record("got \(outcome.result)"); return }
        #expect(try await rig.store.all().isEmpty)
        #expect(await rig.device.writes.isEmpty)
    }

    @Test func aBackupThatCannotBeStoredMeansNothingIsWritten() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore())
        let outcome = await SendRecipeToSlotAction(client: client().client, workflow: rig.workflow)
            .perform(recipeID: 1, slot: 1)
        #expect(outcome.result == .failed("The slot could not be backed up, so nothing was changed."))
        #expect(await rig.nameWrites.isEmpty)
    }

    @Test func settingsThatDoNotTakeAreNamed() async throws {
        let code = TestSupport.code("HighLightTone")
        let rig = try await WorkflowRig(setRejectionCodes: [code: 0x2002])
        let outcome = await SendRecipeToSlotAction(client: client().client, workflow: rig.workflow)
            .perform(recipeID: 1, slot: 1)
        guard case .partiallyFailed(let names) = outcome.result else { Issue.record("got \(outcome.result)"); return }
        #expect(names.contains("HighLightTone"))
        #expect(outcome.dialog.contains("High Light Tone"))
        #expect(outcome.dialog.contains("backed up first"))
        #expect(try await rig.store.all().count == 1)
    }

    @Test func aCameraUnpluggedBeforeTheSendCountsAsNoCamera() async throws {
        let rig = try await WorkflowRig()
        await rig.transport.unplug()
        await waitUntil { await rig.rig.connection.current == .lost(.disconnected) }
        let outcome = await SendRecipeToSlotAction(client: client().client, workflow: rig.workflow)
            .perform(recipeID: 1, slot: 1)
        #expect(outcome.result == .noCamera)
        #expect(await rig.nameWrites.isEmpty)
    }

    @Test func aCameraUnpluggedDuringTheSendIsAConnectionLoss() async throws {
        let rig = try await WorkflowRig(unplugOnCall: 3)
        let outcome = await SendRecipeToSlotAction(client: client().client, workflow: rig.workflow)
            .perform(recipeID: 1, slot: 1)
        #expect(outcome.result == .connectionLost)
        #expect(outcome.dialog.contains("connection was lost"))
        #expect(!outcome.succeeded)
    }

    @Test func theOverwritePromptNamesTheSlotAndTheBackup() {
        #expect(SendRecipeToSlotAction.overwritePrompt(recipeName: "Portra", slot: 4)
            == "Replace C4 with \u{201C}Portra\u{201D}? What is in C4 now is backed up first.")
    }
}

@Suite("ReadSlotsAction")
struct ReadSlotsActionTests {
    @Test func readsAndSpeaksEverySlot() async throws {
        let rig = try ConnectionRig(stringValues: [TestSupport.propSlotName: "Kodak Portra 400"])
        await rig.connectAndWaitUntilReady()
        let action = ReadSlotsAction(
            runner: rig.connection, runtimeSource: try TestSupport.runtime(rig.device))
        let outcome = await action.perform()

        #expect(outcome.result == .slots)
        #expect(outcome.slots.count == 7)
        #expect(outcome.slots.first?.spoken == "C1 Kodak Portra 400")
        #expect(outcome.dialog.hasPrefix("C1 Kodak Portra 400, C2 Kodak Portra 400, "))
        #expect(outcome.dialog.hasSuffix("C7 Kodak Portra 400."))
    }

    @Test func anEmptySlotIsSpokenAsEmpty() {
        #expect(SlotSummary(index: 2, name: "", filmSimulation: "Provia").spoken == "C2 empty")
        #expect(SlotSummary(index: 2, name: "  ", filmSimulation: "Provia").isEmpty)
    }

    @Test func noCameraSaysHowToConnect() async throws {
        let rig = try ConnectionRig()
        let outcome = await ReadSlotsAction(
            runner: rig.connection, runtimeSource: try TestSupport.runtime(rig.device)
        ).perform()
        #expect(outcome.result == .noCamera)
        #expect(outcome.slots.isEmpty)
        #expect(outcome.dialog.contains("USB-C cable"))
    }
}
