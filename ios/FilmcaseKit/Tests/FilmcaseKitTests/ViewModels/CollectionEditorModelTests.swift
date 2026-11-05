import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

private func body(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

@MainActor
@Suite("CollectionEditorModel")
struct CollectionEditorModelTests {
    private func rig(
        writes: @escaping @Sendable (URLRequest) -> StubReply = { _ in reply(json(["id": 9]), status: 201) }
    ) -> ModelRig {
        ModelRig(script: { request in
            guard request.isAuthenticated else { return .fixture("recipe_list") }
            if request.httpMethod == "POST" { return writes(request) }
            return (request.url?.path ?? "").contains("/collections/")
                ? .fixture("collection_detail") : .fixture("recipe_list")
        })
    }

    private func item(_ id: Int, _ name: String = "R") -> CollectionEditorItem {
        CollectionEditorItem(id: id, name: name, filmSimulation: "Provia")
    }

    private func written(_ rig: ModelRig) -> URLRequest? {
        rig.transport.requests.first { $0.httpMethod == "POST" }
    }

    @Test func aNewCollectionNeedsOnlyAName() async {
        let model = CollectionEditorModel(mode: .create, client: rig().client)
        await model.load()
        #expect(model.title == "New collection")
        #expect(!model.canSave)
        model.name = "  Trip "
        #expect(model.canSave)
    }

    @Test func editingLoadsNameAndRecipesInStoredOrder() async throws {
        let rig = rig()
        let model = CollectionEditorModel(mode: .edit(id: 1), client: rig.client)
        await model.load()
        let detail = try JSONDecoder().decode(CollectionDetail.self, from: Fixture.data("collection_detail"))
        #expect(model.title == "Edit collection")
        #expect(model.name == detail.name)
        #expect(model.items.map(\.id) == detail.recipeIDs)
    }

    @Test func candidatesLeaveOutWhatIsAlreadyIn() async throws {
        let model = CollectionEditorModel(mode: .create, client: rig().client)
        await model.load()
        let first = try #require(model.candidates.first)

        model.add(first)
        model.add(first)

        #expect(model.items == [first])
        #expect(!model.candidates.contains(first))

        model.remove(atOffsets: [0])
        #expect(model.items.isEmpty)
        #expect(model.candidates.contains(first))
    }

    @Test func movingFollowsSwiftUIsOffsets() async {
        let model = CollectionEditorModel(mode: .create, client: rig().client)
        for id in 1...4 { model.add(item(id)) }

        model.move(fromOffsets: [0], toOffset: 3)
        #expect(model.items.map(\.id) == [2, 3, 1, 4])

        model.move(fromOffsets: [3], toOffset: 0)
        #expect(model.items.map(\.id) == [4, 2, 3, 1])
    }

    @Test func creatingSendsRecipesInOrder() async throws {
        let rig = rig()
        let model = CollectionEditorModel(mode: .create, client: rig.client)
        await model.load()
        model.name = " Trip "
        model.add(item(3))
        model.add(item(1))

        await model.save()

        #expect(model.savedCollectionID == 9)
        let form = body(try #require(written(rig)))
        #expect(form["name"] as? String == "Trip")
        #expect(form["recipe_ids"] as? [Int] == [3, 1])
    }

    @Test func editingWritesToTheCollection() async throws {
        let rig = rig(writes: { _ in reply(json(["id": 1])) })
        let model = CollectionEditorModel(mode: .edit(id: 1), client: rig.client)
        await model.load()

        await model.save()

        #expect(model.savedCollectionID == 1)
        #expect(try #require(written(rig)).url?.absoluteString.hasSuffix("/collections/1/") == true)
    }

    @Test func aRefusalShowsTheServersWords() async {
        let rig = rig(writes: { _ in reply(json(["error": "A collection with this name already exists."]), status: 400) })
        let model = CollectionEditorModel(mode: .create, client: rig.client)
        await model.load()
        model.name = "Trip"

        await model.save()

        #expect(model.errorMessage == "A collection with this name already exists.")
        #expect(model.savedCollectionID == nil)
    }

    @Test func theNoticeWarnsAboutSlotsAndUnnamedRecipes() {
        let model = CollectionEditorModel(mode: .create, client: rig().client)
        #expect(model.itemsNotice == nil)

        model.add(item(1, ""))
        #expect(model.itemsNotice == "Unnamed recipes need a name before they can go to the camera.")
        #expect(model.items[0].displayName == "Provia #1")

        for id in 2...8 { model.add(item(id)) }
        #expect(model.itemsNotice?.hasPrefix("The camera has 7 slots") == true)
    }
}
