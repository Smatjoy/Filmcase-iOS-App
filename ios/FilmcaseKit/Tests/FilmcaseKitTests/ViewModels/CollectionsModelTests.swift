import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

@MainActor
@Suite("CollectionsModel")
struct CollectionsModelTests {
    private func rig(
        list: Data = Fixture.data("collection_list"), detail: Data = Fixture.data("collection_detail"),
        status: Int = 200
    ) -> ModelRig {
        ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            let path = request.url?.path ?? ""
            return reply(path.hasSuffix("/collections") ? list : detail, status: status)
        })
    }

    @Test func loadsTheCollectionList() async {
        let model = CollectionsModel(client: rig().client)
        #expect(model.state == .loading)
        await model.load()
        #expect(model.state == .loaded)
        #expect(!model.collections.isEmpty)
        #expect(model.collections.map(\.name) == ["Empty", "Street"])
    }

    @Test func noCollectionsIsEmpty() async {
        let model = CollectionsModel(client: rig(list: json(["count": 0, "results": [Any]()])).client)
        await model.load()
        #expect(model.state == .empty)
    }

    @Test func aFailureIsAnErrorAndNoServerIsOffline() async {
        let failing = CollectionsModel(client: rig(list: Fixture.data("error_401"), status: 401).client)
        await failing.load()
        #expect(failing.state == .error("The server rejected the token."))

        let offline = CollectionsModel(client: ModelRig(script: { _ in .transportError() }).client)
        await offline.load()
        #expect(offline.state == .offline)
    }

    @Test func aDetailListsItsRecipesInStoredOrder() async {
        let model = CollectionsModel(client: rig().client)
        await model.loadDetail(id: 2)
        #expect(model.selectedID == 2)
        #expect(model.detailState == .loaded)
        #expect(model.detail?.name == "Street")
        #expect(model.orderedRecipes.map(\.name) == ["Kodak Portra", "Plain Provia"])
    }

    @Test func theStoredOrderWinsOverTheOrderOfTheMembersArray() async {
        var object = jsonObject(fixture: "collection_detail")
        object["recipe_ids"] = [2, 1]
        let model = CollectionsModel(client: rig(detail: json(object)).client)
        await model.loadDetail(id: 2)
        #expect(model.orderedRecipes.map(\.id) == [2, 1])
    }

    @Test func membersTheIDListMissesFollowByPosition() {
        var object = jsonObject(fixture: "collection_detail")
        object["recipe_ids"] = [2]
        let detail = try! JSONDecoder().decode(CollectionDetail.self, from: json(object))
        #expect(CollectionsModel.ordered(detail).map(\.id) == [2, 1])
    }

    @Test func aCollectionWithoutRecipesIsEmpty() async {
        var object = jsonObject(fixture: "collection_detail")
        object["recipe_ids"] = [Int]()
        object["recipes"] = [Any]()
        let model = CollectionsModel(client: rig(detail: json(object)).client)
        await model.loadDetail(id: 2)
        #expect(model.detailState == .empty)
    }

    @Test func aMissingCollectionIsAnError() async {
        let model = CollectionsModel(client: rig(detail: Fixture.data("error_404"), status: 404).client)
        await model.loadDetail(id: 99)
        #expect(model.detailState == .error("The server could not find that."))
    }

    @Test func choosingAnotherCollectionDropsTheOldOnesRecipes() async {
        let model = CollectionsModel(client: rig().client)
        await model.loadDetail(id: 2)
        #expect(!model.orderedRecipes.isEmpty)
        let slow = ModelRig(script: { request in request.isAuthenticated ? reply(Fixture.data("collection_detail")) : .fixture("recipe_list") })
        slow.transport.gate(search: "")
        let other = CollectionsModel(client: slow.client)
        let loading = Task { await other.loadDetail(id: 5) }
        await eventually { slow.transport.held(search: "") == 1 }
        #expect(other.selectedID == 5)
        #expect(other.detailState == .loading)
        #expect(other.orderedRecipes.isEmpty)
        slow.transport.release(search: "")
        await loading.value
        #expect(other.detailState == .loaded)
    }
}
