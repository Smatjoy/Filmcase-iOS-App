import ActivityKit
import FilmcaseKit
import Foundation
import Testing

@testable import Filmcase

@Suite struct IntentsAndActivityTests {
    @Test func recipeEntityMapsASummary() {
        let summary = RecipeEntitySummary(
            id: 7, name: "Kodak Portra 400", filmSimulation: "Classic Chrome", isFavorite: true, imageCount: 12)
        let entity = RecipeEntity(summary)

        #expect(entity.id == 7)
        #expect(entity.name == "Kodak Portra 400")
        #expect(entity.subtitle == "Classic Chrome")
    }

    @Test func reporterIsConstructible() {
        // No ActivityKit calls: only that the adapter exists and is a PushActivityReporter.
        let reporter: any PushActivityReporter = ActivityKitPushReporter()
        _ = reporter
    }
}
