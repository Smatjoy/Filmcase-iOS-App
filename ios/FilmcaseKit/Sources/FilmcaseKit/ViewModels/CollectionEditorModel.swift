// Creating and editing a collection: a name, and recipes in the order they are sent to the
// camera. The server checks the name and the recipes; its refusal is shown as it is.

import Foundation
import Observation

/// A recipe in the collection being edited.
public struct CollectionEditorItem: Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let filmSimulation: String

    public init(id: Int, name: String, filmSimulation: String) {
        self.id = id
        self.name = name
        self.filmSimulation = filmSimulation
    }

    /// The recipe's name, or "Provia #7" when it has none.
    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(filmSimulation) #\(id)" : name
    }

    /// True when it cannot go to the camera yet.
    public var isUnnamed: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
@Observable
public final class CollectionEditorModel {
    public enum Mode: Equatable, Sendable {
        case create
        case edit(id: Int)
    }

    /// The X-T50's custom slots, the body this app targets: more recipes than this
    /// cannot go to the camera together, so the editor says so.
    public static let slotCount = 7

    public let mode: Mode
    public private(set) var state: ContentState = .loading
    public var name = ""
    public private(set) var items: [CollectionEditorItem] = []
    public var searchText = ""
    /// Recipes matching the search that are not in the collection yet.
    public private(set) var candidates: [CollectionEditorItem] = []
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    /// Set when a save went through.
    public private(set) var savedCollectionID: Int?

    @ObservationIgnored private let client: FilmcaseClient
    @ObservationIgnored private var found: [CollectionEditorItem] = []

    public init(mode: Mode, client: FilmcaseClient) {
        self.mode = mode
        self.client = client
    }

    public var title: String { mode == .create ? "New collection" : "Edit collection" }

    public var canSave: Bool {
        state == .loaded && !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A note under the recipes when the collection cannot go to the camera as it is.
    public var itemsNotice: String? {
        if items.count > Self.slotCount {
            return "The camera has \(Self.slotCount) slots, so only \(Self.slotCount) of these recipes can be pushed at a time."
        }
        if items.contains(where: \.isUnnamed) {
            return "Unnamed recipes need a name before they can go to the camera."
        }
        return nil
    }

    public func load() async {
        state = .loading
        do {
            if case .edit(let id) = mode {
                let detail = try await client.collection(id: id)
                name = detail.name
                let byID = Dictionary(detail.recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                items = detail.recipeIDs.compactMap { id in
                    byID[id].map { CollectionEditorItem(id: $0.id, name: $0.name, filmSimulation: $0.filmSimulation) }
                }
            }
            state = .loaded
            await search()
        } catch is CancellationError {
            return
        } catch {
            state = .failure(error)
        }
    }

    /// Find recipes for `searchText`. A failed search leaves the last results in place.
    public func search() async {
        do {
            let page = try await client.recipes(
                pageSize: 50, filters: RecipeFilters(nameSearch: searchText.trimmingCharacters(in: .whitespaces)))
            found = page.results.map {
                CollectionEditorItem(id: $0.id, name: $0.name, filmSimulation: $0.filmSimulation)
            }
            refreshCandidates()
        } catch {
            return
        }
    }

    public func add(_ item: CollectionEditorItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        refreshCandidates()
    }

    public func remove(atOffsets offsets: IndexSet) {
        for offset in offsets.sorted(by: >) { items.remove(at: offset) }
        refreshCandidates()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { items[$0] }
        var kept = items
        for offset in source.sorted(by: >) { kept.remove(at: offset) }
        let insertion = destination - source.filter { $0 < destination }.count
        kept.insert(contentsOf: moving, at: insertion)
        items = kept
    }

    public func clearError() { errorMessage = nil }

    public func save() async {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let fields = CollectionFields(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), recipeIDs: items.map(\.id))
        do {
            switch mode {
            case .create:
                savedCollectionID = try await client.createCollection(fields)
            case .edit(let id):
                try await client.updateCollection(id: id, fields)
                savedCollectionID = id
            }
        } catch is CancellationError {
            return
        } catch FilmcaseClientError.badRequest(let message) {
            errorMessage = message
        } catch {
            errorMessage = UserMessages.text(for: error)
        }
    }

    private func refreshCandidates() {
        let chosen = Set(items.map(\.id))
        candidates = found.filter { !chosen.contains($0.id) }
    }
}
