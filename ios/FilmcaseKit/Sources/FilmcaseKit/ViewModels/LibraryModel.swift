// The recipe list: paged, searchable, filterable. One load is current at a time; a newer
// request (search, facet, favourites, refresh) cancels the older one, and a generation
// number makes sure a page that still arrives late is dropped rather than shown.

import Foundation
import Observation

/// One filter section of the explorer, ready to render.
public struct FacetSection: Equatable, Identifiable, Sendable {
    /// The query parameter name (`film_simulation`).
    public let key: String
    public let label: String
    public let options: [FacetOption]
    public let selectedValues: [String]

    public var id: String { key }
}

@MainActor
@Observable
public final class LibraryModel {
    /// How long typing must pause before the search runs.
    public static let searchDebounce: Duration = .milliseconds(300)
    /// The order filter sections appear in; unlisted facets follow alphabetically.
    static let facetOrder = [
        "film_simulation", "dynamic_range", "d_range_priority", "grain_roughness", "grain_size",
        "color_chrome_effect", "color_chrome_fx_blue", "white_balance", "white_balance_red",
        "white_balance_blue", "highlight", "shadow", "color", "sharpness", "high_iso_nr", "clarity",
        "sensors",
    ]

    public private(set) var state: ContentState = .loading
    public private(set) var recipes: [RecipeSummary] = []
    /// The server's total for the current filters.
    public private(set) var totalCount = 0
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var isRefreshing = false
    /// Set when the next page failed; the rows already shown stay.
    public private(set) var loadMoreError: String?
    public private(set) var selectedFacets: [String: [String]] = [:]
    /// What to say once a search or filter change has finished loading ("12 recipes",
    /// "1 recipe", "No recipes match"). Nil while loading, after a failure, and until the
    /// first search or filter change; the first load and a refresh never set it.
    public private(set) var resultsAnnouncement: String?

    public var searchText = "" {
        didSet { if searchText != oldValue { searchTextChanged() } }
    }
    public var favoritesOnly = false {
        didSet { if favoritesOnly != oldValue { filtersChanged() } }
    }

    @ObservationIgnored private let client: FilmcaseClient
    @ObservationIgnored private let clock: any FilmcaseClock
    @ObservationIgnored private let pageSize: Int
    /// A load starts when one of this many last rows appears.
    @ObservationIgnored private let prefetchDistance: Int
    @ObservationIgnored private var lastFacets: [String: Facet] = [:]
    @ObservationIgnored private var currentPage = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appliedSearch = ""
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    public init(
        client: FilmcaseClient, clock: any FilmcaseClock = SystemClock(),
        pageSize: Int = 24, prefetchDistance: Int = 5
    ) {
        self.client = client
        self.clock = clock
        self.pageSize = pageSize
        self.prefetchDistance = prefetchDistance
    }

    // --- derived ---

    public var facetSections: [FacetSection] {
        let order = Self.facetOrder
        let keys = lastFacets.keys.sorted { lhs, rhs in
            switch (order.firstIndex(of: lhs), order.firstIndex(of: rhs)) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs < rhs
            }
        }
        return keys.compactMap { key in
            guard let facet = lastFacets[key] else { return nil }
            return FacetSection(
                key: key, label: facet.label, options: facet.options,
                selectedValues: selectedFacets[key] ?? [])
        }
    }

    public var hasActiveFilters: Bool {
        favoritesOnly || !selectedFacets.isEmpty
    }

    // --- intents ---

    /// First load, from the view's `.task`. Does nothing once something has loaded.
    public func loadIfNeeded() async {
        guard !hasStarted else { return }
        await reload()
    }

    /// Load the first page again with the current filters, waiting for it.
    public func reload() async {
        debounceTask?.cancel()
        debounceTask = nil
        await beginLoad(page: 1, append: false, refreshing: false).value
    }

    /// Pull to refresh: like `reload`, but the rows stay on screen meanwhile.
    public func refresh() async {
        debounceTask?.cancel()
        debounceTask = nil
        isRefreshing = true
        await beginLoad(page: 1, append: false, refreshing: true).value
        isRefreshing = false
    }

    /// Call as each row appears; loads the next page when *currentItem* is near the end.
    public func loadMoreIfNeeded(currentItem: RecipeSummary) {
        guard hasMore, !isLoadingMore, state == .loaded else { return }
        guard let index = recipes.firstIndex(where: { $0.id == currentItem.id }),
              index >= recipes.count - prefetchDistance
        else { return }
        _ = beginLoad(page: currentPage + 1, append: true, refreshing: false)
    }

    /// Try the failed next page again.
    public func retryLoadMore() {
        guard hasMore, !isLoadingMore, loadMoreError != nil else { return }
        _ = beginLoad(page: currentPage + 1, append: true, refreshing: false)
    }

    public func toggleFacet(_ key: String, value: String) {
        var values = selectedFacets[key] ?? []
        if let index = values.firstIndex(of: value) {
            values.remove(at: index)
        } else {
            values.append(value)
        }
        selectedFacets[key] = values.isEmpty ? nil : values
        filtersChanged()
    }

    public func clearFilters() {
        guard hasActiveFilters else { return }
        selectedFacets = [:]
        if favoritesOnly {
            favoritesOnly = false   // its didSet reloads
        } else {
            filtersChanged()
        }
    }

    // --- internals ---

    private func searchTextChanged() {
        debounceTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != appliedSearch else {
            debounceTask = nil
            return
        }
        let clock = self.clock
        debounceTask = Task { [weak self] in
            do { try await clock.sleep(for: LibraryModel.searchDebounce) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            _ = self.beginLoad(page: 1, append: false, refreshing: false, announcesResults: true)
        }
    }

    private func filtersChanged() {
        debounceTask?.cancel()
        debounceTask = nil
        _ = beginLoad(page: 1, append: false, refreshing: false, announcesResults: true)
    }

    private var currentFilters: RecipeFilters {
        RecipeFilters(
            nameSearch: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            facets: selectedFacets)
    }

    /// Start a load, cancelling whichever was running. The returned task finishes when the
    /// load has been applied (or dropped as stale).
    private func beginLoad(
        page: Int, append: Bool, refreshing: Bool, announcesResults: Bool = false
    ) -> Task<Void, Never> {
        loadTask?.cancel()
        generation += 1
        hasStarted = true
        let token = generation
        let filters = currentFilters
        let favorites = favoritesOnly
        if append {
            isLoadingMore = true
            loadMoreError = nil
        } else {
            resultsAnnouncement = nil
            appliedSearch = filters.nameSearch
            isLoadingMore = false
            loadMoreError = nil
            if !refreshing { state = .loading }
        }
        let client = self.client
        let pageSize = self.pageSize
        let task = Task { [weak self] in
            let outcome: Result<RecipePage, any Error>
            do {
                outcome = .success(try await client.recipes(
                    page: page, pageSize: pageSize, filters: filters, favoritesOnly: favorites))
            } catch {
                outcome = .failure(error)
            }
            self?.finish(
                outcome, token: token, page: page, append: append, announcesResults: announcesResults)
        }
        loadTask = task
        return task
    }

    private func finish(
        _ outcome: Result<RecipePage, any Error>, token: Int, page: Int, append: Bool,
        announcesResults: Bool
    ) {
        // A newer load started since this one did: whatever it found is out of date.
        guard token == generation else { return }
        switch outcome {
        case .success(let result):
            lastFacets = result.facets
            totalCount = result.count
            hasMore = result.next != nil
            currentPage = page
            if append {
                isLoadingMore = false
                let known = Set(recipes.map(\.id))
                recipes += result.results.filter { !known.contains($0.id) }
            } else {
                var seen = Set<Int>()
                recipes = result.results.filter { seen.insert($0.id).inserted }
            }
            state = recipes.isEmpty ? .empty : .loaded
            if announcesResults && !append {
                resultsAnnouncement = UserMessages.resultsAnnouncement(count: result.count)
            }
        case .failure(let error):
            if append {
                isLoadingMore = false
                if !(error is CancellationError) { loadMoreError = UserMessages.text(for: error) }
            } else if !(error is CancellationError) {
                state = .failure(error)
            }
        }
    }
}
