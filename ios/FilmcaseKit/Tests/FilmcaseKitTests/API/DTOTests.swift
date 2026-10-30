import Foundation
import Testing
@testable import FilmcaseKit

@Suite("API DTOs decode the recorded fixtures")
struct DTOTests {
    @Test("recipe list")
    func recipeList() throws {
        let page = try Fixture.decode(RecipePage.self, "recipe_list")
        #expect(page.count == 2)
        #expect(page.next == nil)
        #expect(page.previous == nil)
        #expect(page.results.count == 2)
        let first = try #require(page.results.first)
        #expect(first.name == "Kodak Portra")
        #expect(first.filmSimulation == "Classic Chrome")
        #expect(first.version == RecipeVersion(position: 1, label: "v1"))
        #expect(first.coverThumbnailURL?.hasPrefix("/api/v1/images/") == true)
        #expect(page.results.last?.coverThumbnailURL == nil)
        #expect(first.isFavorite)
        #expect(page.results.last?.isFavorite == false)
        #expect(!page.facets.isEmpty)
        let sensors = try #require(page.facets["sensors"])
        #expect(sensors.label == "Sensor")
        #expect(sensors.options.contains { $0.value == "none" && $0.label == "Not assigned" })
        let film = try #require(page.facets["film_simulation"])
        #expect(film.options.map(\.value) == ["Classic Chrome", "Provia"])
        #expect(film.options.allSatisfy { $0.label == nil && $0.available })
    }

    @Test("recipe list second page carries a previous link")
    func recipeListPage2() throws {
        let page = try Fixture.decode(RecipePage.self, "recipe_list_page2")
        #expect(page.count == 2)
        #expect(page.results.count == 1)
        #expect(page.next == nil)
        #expect(page.previous?.hasPrefix("/api/v1/recipes/") == true)
    }

    @Test("favourites-only recipe list")
    func recipeListFavorites() throws {
        let page = try Fixture.decode(RecipePage.self, "recipe_list_favorites")
        #expect(page.count == 1)
        #expect(page.results.allSatisfy { $0.isFavorite })
    }

    @Test("recipe detail")
    func recipeDetail() throws {
        let detail = try Fixture.decode(RecipeDetail.self, "recipe_detail")
        #expect(detail.name == "Kodak Portra")
        #expect(detail.dynamicRange == "DR200")
        #expect(detail.dRangePriority == "Off")
        #expect(detail.colorChromeFXBlue == "Off")
        #expect(detail.highlight == -1)
        #expect(detail.shadow == 1)
        #expect(detail.color == 2)
        #expect(detail.highISONR == 0)
        #expect(detail.monochromaticColorWarmCool == nil)
        #expect(!detail.isMonochromatic)
        #expect(detail.isFavorite)
        #expect(detail.sensors == ["X-Trans V"])
        #expect(detail.bodies.contains("X-T50"))
        #expect(detail.version == RecipeVersion(position: 1, label: "v1"))
        #expect(detail.versionLine.map(\.isCurrent) == [true, false])
        #expect(detail.collections.map(\.name) == ["Street"])
        #expect(detail.cameraPayloadURL == "/api/v1/recipes/\(detail.id)/camera-payload.json")
        #expect(detail.coverImageURL?.hasSuffix("/file") == true)
        #expect(detail.coverThumbnailURL?.hasSuffix("/thumbnail") == true)
    }

    @Test("collection list")
    func collectionList() throws {
        let list = try Fixture.decode(CollectionList.self, "collection_list")
        #expect(list.count == 2)
        #expect(list.results.map(\.name) == ["Empty", "Street"])
        let street = try #require(list.results.last)
        #expect(street.recipeCount == 2)
        #expect(street.filmSimulations == ["Classic Chrome", "Provia"])
        #expect(street.coverThumbnailURLs.compactMap { $0 }.count == 1)
        #expect(list.results.first?.coverThumbnailURLs.isEmpty == true)
    }

    @Test("collection detail")
    func collectionDetail() throws {
        let detail = try Fixture.decode(CollectionDetail.self, "collection_detail")
        #expect(detail.name == "Street")
        #expect(detail.recipeIDs.count == 2)
        #expect(detail.recipes.map(\.id) == detail.recipeIDs)
        #expect(detail.recipes.map(\.position) == [0, 1])
        #expect(detail.recipes.first?.name == "Kodak Portra")
    }

    @Test("error bodies", arguments: [
        ("error_400", "page must be a positive integer."),
        ("error_401", "A valid bearer token is required."),
        ("error_404", "Not found."),
    ])
    func errorBody(_ name: String, _ message: String) throws {
        #expect(try Fixture.decode(APIErrorBody.self, name).error == message)
    }

    @Test("503 body names the missing setting")
    func error503() throws {
        #expect(try Fixture.decode(APIErrorBody.self, "error_503").error.contains("FILMCASE_API_TOKEN"))
    }
}
