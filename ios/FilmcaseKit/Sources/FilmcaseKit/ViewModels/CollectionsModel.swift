// Collections: the list, and one collection's recipes in stored order.

import Foundation
import Observation

@MainActor
@Observable
public final class CollectionsModel {
    public private(set) var state: ContentState = .loading
    public private(set) var collections: [CollectionSummary] = []

    public private(set) var selectedID: Int?
    public private(set) var detailState: ContentState = .loading
    public private(set) var detail: CollectionDetail?
    /// The selected collection's recipes, in the order the collection stores them.
    public private(set) var orderedRecipes: [CollectionMember] = []

    /// Why the last delete failed, as a sentence.
    public private(set) var removeError: String?

    @ObservationIgnored private let client: FilmcaseClient
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var detailGeneration = 0

    public init(client: FilmcaseClient) {
        self.client = client
    }

    // --- per-collection reads, so a view never shows another collection's data ---

    /// Whether the model's detail is the one for *id* (not a collection opened before it).
    public func isShowing(id: Int) -> Bool { selectedID == id }

    /// The state of collection *id*'s detail: `.loading` until its own load has begun.
    public func detailState(for id: Int) -> ContentState {
        isShowing(id: id) ? detailState : .loading
    }

    /// Collection *id*'s detail, or nil while another collection is selected.
    public func detail(for id: Int) -> CollectionDetail? {
        isShowing(id: id) ? detail : nil
    }

    /// Collection *id*'s recipes in stored order; empty while another collection is selected.
    public func orderedRecipes(for id: Int) -> [CollectionMember] {
        isShowing(id: id) ? orderedRecipes : []
    }

    /// Delete a collection and refresh the list. False when it failed (`removeError`).
    @discardableResult
    public func remove(id: Int) async -> Bool {
        removeError = nil
        do {
            try await client.removeCollection(id: id)
        } catch is CancellationError {
            return false
        } catch {
            removeError = UserMessages.text(for: error)
            return false
        }
        await load()
        return true
    }

    public func clearRemoveError() { removeError = nil }

    public func load() async {
        listGeneration += 1
        let token = listGeneration
        if collections.isEmpty { state = .loading }
        do {
            let list = try await client.collections()
            guard token == listGeneration else { return }
            collections = list.results
            state = collections.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard token == listGeneration else { return }
            state = .failure(error)
        }
    }

    public func loadDetail(id: Int) async {
        detailGeneration += 1
        let token = detailGeneration
        if selectedID != id {
            selectedID = id
            detail = nil
            orderedRecipes = []
        }
        if detail == nil { detailState = .loading }
        do {
            let loaded = try await client.collection(id: id)
            guard token == detailGeneration else { return }
            detail = loaded
            orderedRecipes = Self.ordered(loaded)
            detailState = orderedRecipes.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard token == detailGeneration else { return }
            detailState = .failure(error)
        }
    }

    /// Members in `recipe_ids` order; any member that list does not name follows by `position`.
    static func ordered(_ detail: CollectionDetail) -> [CollectionMember] {
        let byID = Dictionary(detail.recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let named = detail.recipeIDs.compactMap { byID[$0] }
        let namedIDs = Set(named.map(\.id))
        let rest = detail.recipes.filter { !namedIDs.contains($0.id) }.sorted { $0.position < $1.position }
        return named + rest
    }
}
