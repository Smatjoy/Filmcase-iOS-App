import Foundation
import Testing
@testable import FilmcaseKit

@MainActor @Suite struct AccessibilityTextTests {
    private func collection(_ name: String, _ count: Int) -> CollectionSummary {
        CollectionSummary(id: 1, name: name, recipeCount: count, filmSimulations: [], coverThumbnailURLs: [])
    }

    private func option(_ value: String, label: String? = nil, count: Int) -> FacetOption {
        FacetOption(value: value, label: label, count: count, available: true, selected: false)
    }

    @Test(arguments: [(3, "Summer, 3 recipes"), (1, "Summer, 1 recipe"), (0, "Summer, 0 recipes")])
    func collectionLabelPluralises(count: Int, expected: String) {
        #expect(collection("Summer", count).accessibilityLabel == expected)
    }

    @Test func aBlankCollectionNameFallsBack() {
        #expect(collection("  ", 2).accessibilityLabel == "Untitled collection, 2 recipes")
    }

    @Test func facetOptionLabelUsesLabelOrValueAndCount() {
        #expect(option("Kodak Portra 400", count: 12).accessibilityLabel == "Kodak Portra 400, 12 recipes")
        #expect(option("Velvia", count: 1).accessibilityLabel == "Velvia, 1 recipe")
        #expect(option("x-trans-v", label: "X-Trans V", count: 4).accessibilityLabel == "X-Trans V, 4 recipes")
        #expect(option("a", label: "", count: 0).accessibilityLabel == "a, 0 recipes")
    }

    @Test func diffRowsSayWhatDidNotTake() {
        let outcome = PushSheetModel.Outcome(
            action: .push, slot: 3, result: .partiallyFailed(["HighLightTone", "Clarity"]))
        #expect(outcome.diffAccessibilityLabels == ["High Light Tone did not take", "Clarity did not take"])
        #expect(PushSheetModel.Outcome(action: .push, slot: 3, result: .verified).diffAccessibilityLabels.isEmpty)
    }

    @Test func partialFailuresShowTheReadableNames() {
        let result = SlotPushResult.partiallyFailed(["DynamicRange", "HighLightTone"])
        #expect(result.detailText == "Not applied: Dynamic Range, High Light Tone")
        #expect(CollectionPushModel.SlotStatus.done(result).detailText == "Not applied: Dynamic Range, High Light Tone")
        #expect(PushSheetModel.Outcome(action: .push, slot: 2, result: .partiallyFailed(["DynamicRange", "HighLightTone"])).detailText
            == "Not applied: Dynamic Range, High Light Tone")
    }

    @Test func otherResultsHaveNoDetail() {
        #expect(SlotPushResult.verified.detailText == nil)
        #expect(SlotPushResult.connectionLost.detailText == nil)
        #expect(SlotPushResult.partiallyFailed([]).detailText == nil)
        #expect(CollectionPushModel.SlotStatus.waiting.detailText == nil)
        #expect(CollectionPushModel.SlotStatus.pushing.detailText == nil)
        #expect(PushSheetModel.Outcome(action: .push, slot: 2, result: .failed("x")).detailText == nil)
    }

    // --- collection push ---

    private func report(_ results: [Int: SlotPushResult], remaining: [Int] = []) -> CollectionPushReport {
        let slots = results.keys.sorted()
        return CollectionPushReport(
            assignment: Dictionary(uniqueKeysWithValues: slots.map { ($0, $0 * 10) }),
            results: results, done: slots, remaining: remaining)
    }

    @Test func aCleanRunIsAnnounced() {
        let all = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, SlotPushResult.verified) })
        #expect(CollectionPushModel.completionAnnouncement(for: .finished(report(all))) == "Collection pushed: 7 verified")
    }

    @Test func aRunWithProblemsNamesThem() {
        var results = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, SlotPushResult.verified) })
        results[4] = .partiallyFailed(["A", "B"])
        #expect(CollectionPushModel.completionAnnouncement(for: .finished(report(results)))
            == "6 verified, C4: 2 settings not applied")
    }

    @Test func interruptedRestoringAndRestored() {
        let partial = report([1: .verified], remaining: [2])
        #expect(CollectionPushModel.completionAnnouncement(for: .interrupted(partial, message: "Backup failed."))
            == "Backup failed.")
        #expect(CollectionPushModel.completionAnnouncement(for: .interrupted(partial, message: nil))
            == "The push stopped.")
        #expect(CollectionPushModel.completionAnnouncement(for: .restoring) == "Restoring slots")
        let restored = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, SlotPushResult.verified) })
        #expect(CollectionPushModel.completionAnnouncement(for: .restored(restored)) == "Restored 7 slots")
        #expect(CollectionPushModel.completionAnnouncement(for: .restored([1: .verified])) == "Restored 1 slot")
        #expect(CollectionPushModel.completionAnnouncement(for: .restored([:])) == "Nothing to restore")
    }

    @Test func editingAndRunningSayNothing() {
        #expect(CollectionPushModel.completionAnnouncement(for: .editing) == nil)
        #expect(CollectionPushModel.completionAnnouncement(for: .running) == nil)
    }

    // --- library results ---

    private func library(_ rig: ModelRig) -> LibraryModel {
        LibraryModel(client: rig.client, clock: rig.clock, pageSize: 3, prefetchDistance: 1)
    }

    @Test func resultsAreAnnouncedOnlyWhenAFilterChangeCompletes() async {
        let rig = ModelRig(script: searchScript { request in
            request.queryValue("favorite") == "true" ? pageBody(ids: [1], count: 1) : pageBody(ids: [1, 2, 3], count: 12)
        })
        let model = library(rig)
        #expect(model.resultsAnnouncement == nil)
        await model.loadIfNeeded()
        #expect(model.resultsAnnouncement == nil, "the first load is not a change")

        model.favoritesOnly = true
        #expect(model.resultsAnnouncement == nil, "nil while loading")
        await eventually { model.state == .loaded && model.recipes.count == 1 }
        #expect(model.resultsAnnouncement == "1 recipe")

        model.favoritesOnly = false
        #expect(model.resultsAnnouncement == nil)
        await eventually { model.state == .loaded && model.recipes.count == 3 }
        #expect(model.resultsAnnouncement == "12 recipes")

        await model.refresh()
        #expect(model.resultsAnnouncement == nil, "a refresh is not a change")
    }

    @Test func noMatchesIsAnnounced() async {
        let rig = ModelRig(script: searchScript { request in
            request.queryValue("favorite") == "true" ? pageBody(ids: []) : pageBody(ids: [1, 2, 3], count: 3)
        })
        let model = library(rig)
        await model.loadIfNeeded()
        model.favoritesOnly = true
        await eventually { model.state == .empty }
        #expect(model.resultsAnnouncement == "No recipes match")
    }

    // --- onboarding ---

    @Test func theFingerprintIsSpokenInUppercasePairs() {
        #expect(OnboardingModel.spoken(fingerprint: "aabbcc00") == "AA, BB, CC, 00")
        #expect(OnboardingModel.spoken(fingerprint: "AA:BB:CC") == "AA, BB, CC")
    }
}
