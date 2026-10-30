import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FilmcaseKit

@MainActor
@Suite("LibraryModel")
struct LibraryModelTests {
    /// Pages of three: page 1 is 1-3, page 2 is 3-5 (3 repeated), page 3 is 6.
    private static func pagedScript() -> @Sendable (URLRequest) -> StubReply {
        searchScript { request in
            switch request.queryValue("page") {
            case "2": pageBody(ids: [3, 4, 5], count: 6, hasNext: true)
            case "3": pageBody(ids: [6], count: 6)
            default: pageBody(ids: [1, 2, 3], count: 6, hasNext: true)
            }
        }
    }

    private func model(_ rig: ModelRig, prefetch: Int = 1) -> LibraryModel {
        LibraryModel(client: rig.client, clock: rig.clock, pageSize: 3, prefetchDistance: prefetch)
    }

    // --- states ---

    @Test func startsLoadingThenShowsTheFirstPage() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        #expect(library.state == .loading)
        await library.loadIfNeeded()
        #expect(library.state == .loaded)
        #expect(library.recipes.map(\.id) == [1, 2, 3])
        #expect(library.totalCount == 6)
        #expect(library.hasMore)
    }

    @Test func loadIfNeededRunsOnce() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        await library.loadIfNeeded()
        #expect(rig.transport.authenticatedRequests.count == 1)
    }

    @Test func anEmptyResultIsEmpty() async {
        let rig = ModelRig(script: searchScript { _ in pageBody(ids: []) })
        let library = model(rig)
        await library.loadIfNeeded()
        #expect(library.state == .empty)
        #expect(library.recipes.isEmpty)
    }

    @Test func aRejectedTokenIsAnError() async {
        let rig = ModelRig(script: { request in
            request.isAuthenticated ? reply(Fixture.data("error_401"), status: 401) : reply(pageBody(ids: [1]))
        })
        let library = model(rig)
        await library.loadIfNeeded()
        #expect(library.state == .error("The server rejected the token."))
    }

    @Test func noServerAnsweringIsOffline() async {
        let rig = ModelRig(script: { _ in .transportError() })
        let library = model(rig)
        await library.loadIfNeeded()
        #expect(library.state == .offline)
    }

    @Test func aReloadAfterAFailureRecovers() async {
        let rig = ModelRig(script: { request in
            request.isAuthenticated ? reply(Fixture.data("error_503"), status: 503) : reply(pageBody(ids: [1]))
        })
        let library = model(rig)
        await library.loadIfNeeded()
        #expect(library.state == .error("The server has no API token configured."))

        rig.transport.setScript(Self.pagedScript())
        await library.reload()
        #expect(library.state == .loaded)
    }

    // --- paging ---

    @Test func nearTheEndTheNextPageIsAppendedWithoutDuplicates() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()

        library.loadMoreIfNeeded(currentItem: library.recipes[0])
        #expect(!library.isLoadingMore, "the first row is far from the end")

        library.loadMoreIfNeeded(currentItem: library.recipes[2])
        #expect(library.isLoadingMore)
        await eventually { !library.isLoadingMore }

        #expect(library.recipes.map(\.id) == [1, 2, 3, 4, 5], "3 came back on page 2 and is kept once")
        #expect(library.hasMore)
        library.loadMoreIfNeeded(currentItem: library.recipes[4])
        await eventually { !library.hasMore }
        #expect(library.recipes.map(\.id) == [1, 2, 3, 4, 5, 6])
        #expect(library.state == .loaded)
    }

    @Test func aPageInFlightIsNotRequestedTwice() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        let last = library.recipes[2]
        library.loadMoreIfNeeded(currentItem: last)
        library.loadMoreIfNeeded(currentItem: last)
        await eventually { !library.isLoadingMore }
        #expect(rig.transport.authenticatedRequests.filter { $0.queryValue("page") == "2" }.count == 1)
    }

    @Test func nothingMoreIsRequestedOnTheLastPage() async {
        let rig = ModelRig(script: searchScript { _ in pageBody(ids: [1, 2]) })
        let library = model(rig)
        await library.loadIfNeeded()
        library.loadMoreIfNeeded(currentItem: library.recipes[1])
        #expect(!library.hasMore)
        #expect(!library.isLoadingMore)
        #expect(rig.transport.authenticatedRequests.count == 1)
    }

    @Test func aFailedNextPageKeepsTheRowsAndCanBeRetried() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        rig.transport.setScript(searchScript { _ in pageBody(ids: []) })
        rig.transport.setScript { request in
            request.isAuthenticated ? reply(Fixture.data("error_503"), status: 503) : reply(pageBody(ids: [1]))
        }

        library.loadMoreIfNeeded(currentItem: library.recipes[2])
        await eventually { !library.isLoadingMore }
        #expect(library.loadMoreError == "The server has no API token configured.")
        #expect(library.state == .loaded)
        #expect(library.recipes.map(\.id) == [1, 2, 3])

        rig.transport.setScript(Self.pagedScript())
        library.retryLoadMore()
        await eventually { !library.isLoadingMore }
        #expect(library.loadMoreError == nil)
        #expect(library.recipes.map(\.id) == [1, 2, 3, 4, 5])
    }

    // --- refresh ---

    @Test func refreshKeepsTheRowsOnScreenAndReplacesThem() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        rig.transport.setScript(searchScript { _ in pageBody(ids: [9, 8]) })
        rig.transport.gate(search: "")

        let refreshing = Task { await library.refresh() }
        await eventually { rig.transport.held(search: "") == 1 }
        #expect(library.isRefreshing)
        #expect(library.state == .loaded, "no spinner replaces the list")
        #expect(library.recipes.map(\.id) == [1, 2, 3])

        rig.transport.release(search: "")
        await refreshing.value
        #expect(!library.isRefreshing)
        #expect(library.recipes.map(\.id) == [9, 8])
    }

    @Test func aFailedRefreshReportsOfflineButKeepsTheRows() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        rig.transport.setScript { _ in .transportError() }
        await library.refresh()
        #expect(library.state == .offline)
        #expect(library.recipes.map(\.id) == [1, 2, 3])
    }

    // --- filters ---

    @Test func facetSectionsComeFromTheResponseInDisplayOrder() async {
        let facets: [String: Any] = [
            "sensors": facetJSON(label: "Sensor", values: ["X-Trans V"]),
            "zzz": facetJSON(label: "Zed", values: ["z"]),
            "dynamic_range": facetJSON(label: "Dynamic Range", values: ["DR100", "DR200"]),
            "film_simulation": facetJSON(label: "Film Simulation", values: ["Provia"]),
        ]
        let body = pageBody(ids: [1], facets: facets)
        let rig = ModelRig(script: searchScript { _ in body })
        let library = model(rig)
        await library.loadIfNeeded()
        #expect(library.facetSections.map(\.key) == ["film_simulation", "dynamic_range", "sensors", "zzz"])
        #expect(library.facetSections[1].options.map(\.value) == ["DR100", "DR200"])
        #expect(library.facetSections[1].label == "Dynamic Range")
    }

    @Test func choosingAFacetValueReloadsWithThatFilter() async {
        // The page carries the number of selected values, so the rows show which request won.
        let rig = ModelRig(script: searchScript { request in
            let selected = request.queryValues("film_simulation").count
            return selected == 0 ? pageBody(ids: [1, 2, 3]) : pageBody(ids: [100 + selected])
        })
        let library = model(rig)
        await library.loadIfNeeded()

        library.toggleFacet("film_simulation", value: "Provia")
        library.toggleFacet("film_simulation", value: "Velvia")
        await eventually { library.state == .loaded && library.recipes.map(\.id) == [102] }

        #expect(library.recipes.map(\.id) == [102])
        #expect(rig.transport.authenticatedRequests.contains { $0.queryValues("film_simulation") == ["Provia", "Velvia"] })
        #expect(library.hasActiveFilters)
        #expect(library.selectedFacets == ["film_simulation": ["Provia", "Velvia"]])

        library.toggleFacet("film_simulation", value: "Provia")
        library.toggleFacet("film_simulation", value: "Velvia")
        #expect(library.selectedFacets.isEmpty)
        #expect(!library.hasActiveFilters)
    }

    @Test func favouritesOnlyAsksTheServerForFavourites() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        library.favoritesOnly = true
        await eventually { rig.transport.authenticatedRequests.count == 2 && library.state == .loaded }
        #expect(rig.transport.authenticatedRequests.last?.queryValue("favorite") == "true")
        #expect(rig.transport.authenticatedRequests.first?.queryValue("favorite") == nil)
    }

    @Test func clearFiltersResetsFacetsAndFavourites() async {
        // Filtered requests get [50]; unfiltered ones get a new page each time.
        let unfiltered = Mutex(0)
        let rig = ModelRig(script: searchScript { request in
            if request.queryValue("favorite") != nil || !request.queryValues("film_simulation").isEmpty {
                return pageBody(ids: [50])
            }
            let n = unfiltered.withLock { value -> Int in value += 1; return value }
            return pageBody(ids: [n * 10])
        })
        let library = model(rig)
        await library.loadIfNeeded()
        #expect(library.recipes.map(\.id) == [10])

        library.favoritesOnly = true
        library.toggleFacet("film_simulation", value: "Provia")
        await eventually { library.state == .loaded && library.recipes.map(\.id) == [50] }
        library.clearFilters()
        #expect(!library.hasActiveFilters)
        #expect(library.favoritesOnly == false)
        #expect(library.selectedFacets.isEmpty)
        await eventually { library.state == .loaded && library.recipes.map(\.id) == [20] }
        #expect(library.recipes.map(\.id) == [20], "the unfiltered page replaced the filtered one")
    }

    // --- search debounce ---

    @Test func searchWaitsThreeHundredMillisecondsAfterTheLastKeystroke() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        let before = rig.transport.authenticatedRequests.count

        library.searchText = "p"
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: .milliseconds(299))
        library.searchText = "po"
        await rig.clock.waitForSleeps(2)
        rig.clock.advance(by: .milliseconds(299))
        #expect(rig.transport.authenticatedRequests.count == before, "still inside the quiet period")

        rig.clock.advance(by: .milliseconds(1))
        await eventually { rig.transport.authenticatedRequests.count == before + 1 && library.state == .loaded }

        let searches = rig.transport.authenticatedRequests.dropFirst(before).map { $0.queryValue("name_search") }
        #expect(searches == ["po"], "the superseded keystroke never searched")
        #expect(rig.clock.sleeps == [.milliseconds(300), .milliseconds(300)])
    }

    @Test func typingBackToTheAppliedSearchCancelsThePendingOne() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        library.searchText = "x"
        await rig.clock.waitForSleeps(1)
        library.searchText = ""
        rig.clock.advance(by: .seconds(1))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.transport.authenticatedRequests.count == 1)
    }

    @Test func refreshAppliesTheTypedSearchWithoutWaiting() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        library.searchText = "kodak"
        await library.refresh()
        #expect(rig.transport.authenticatedRequests.last?.queryValue("name_search") == "kodak")
    }

    // --- stale loads ---

    @Test func anOlderSearchAnsweringLateNeverOverwritesTheNewerOne() async {
        // This transport ignores cancellation, so the old answer really does arrive late.
        let rig = ModelRig(honorsCancellation: false, script: searchScript { request in
            switch request.queryValue("name_search") {
            case "old": pageBody(ids: [100, 101])
            case "new": pageBody(ids: [200])
            default: pageBody(ids: [1, 2, 3])
            }
        })
        let library = model(rig)
        await library.loadIfNeeded()
        rig.transport.gate(search: "old")
        rig.transport.gate(search: "new")

        library.searchText = "old"
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: .milliseconds(300))
        await eventually { rig.transport.held(search: "old") == 1 }

        library.searchText = "new"
        await rig.clock.waitForSleeps(2)
        rig.clock.advance(by: .milliseconds(300))
        await eventually { rig.transport.held(search: "new") == 1 }

        rig.transport.release(search: "new")
        await eventually { library.recipes.map(\.id) == [200] }
        rig.transport.release(search: "old")
        // Let the late answer be processed, then check it was dropped.
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(library.recipes.map(\.id) == [200])
        #expect(library.state == .loaded)
    }

    @Test func aFilterChangeCancelsTheLoadInFlight() async {
        let rig = ModelRig(script: Self.pagedScript())
        let library = model(rig)
        await library.loadIfNeeded()
        rig.transport.gate(search: "")

        library.favoritesOnly = true
        await eventually { rig.transport.held(search: "") == 1 }
        library.toggleFacet("film_simulation", value: "Provia")
        await eventually { rig.transport.cancellations >= 1 }
        rig.transport.release(search: "")
        await eventually { library.state == .loaded && rig.transport.authenticatedRequests.count == 3 }

        #expect(rig.transport.cancellations == 1, "the favourites load was cancelled, not left running")
        #expect(library.recipes.map(\.id) == [1, 2, 3])
    }

    @Test func aPageForOldFiltersIsDroppedWhenFiltersChangedMeanwhile() async {
        let rig = ModelRig(honorsCancellation: false, script: searchScript { request in
            request.queryValue("page") == "2" ? pageBody(ids: [4, 5, 6], count: 6) : pageBody(ids: [1, 2, 3], count: 6, hasNext: true)
        })
        let library = model(rig)
        await library.loadIfNeeded()
        rig.transport.gate(search: "")

        library.loadMoreIfNeeded(currentItem: library.recipes[2])
        await eventually { rig.transport.held(search: "") == 1 }
        rig.transport.setScript(searchScript { _ in pageBody(ids: [7]) })
        library.favoritesOnly = true
        await eventually { rig.transport.held(search: "") == 2 }
        rig.transport.release(search: "")
        await eventually { library.recipes.map(\.id) == [7] }
        for _ in 0..<200 { await Task.yield() }

        #expect(library.recipes.map(\.id) == [7], "page 2 of the old filter was not appended")
        #expect(!library.isLoadingMore)
    }
}
