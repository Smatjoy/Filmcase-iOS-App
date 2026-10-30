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

    @ObservationIgnored private let client: FilmcaseClient
    @ObservationIgnored private var listGeneration = 0
    @ObservationIgnored private var detailGeneration = 0

    public init(client: FilmcaseClient) {
        self.client = client
    }

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
