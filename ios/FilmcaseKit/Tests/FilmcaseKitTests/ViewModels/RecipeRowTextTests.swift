import Foundation
import Testing
@testable import FilmcaseKit

private func summary(name: String, isFavorite: Bool = false, id: Int = 7) throws -> RecipeSummary {
    var object = summaryJSON(id: id)
    object["name"] = name
    object["film_simulation"] = "Classic Chrome"
    object["is_favorite"] = isFavorite
    return try JSONDecoder().decode(RecipeSummary.self, from: json(object))
}

@Suite("Recipe row text")
struct RecipeRowTextTests {
    @Test func aNamedRecipeReadsNameAndFilmSimulation() throws {
        #expect(try summary(name: "Kodak Portra 400").accessibilityLabel == "Kodak Portra 400, Classic Chrome")
    }

    @Test func aFavouriteSaysSo() throws {
        #expect(try summary(name: "Kodak Portra 400", isFavorite: true).accessibilityLabel
            == "Kodak Portra 400, Classic Chrome, favourite")
    }

    @Test(arguments: ["", "   ", "\n"])
    func anUnnamedRecipeUsesTheWebFallback(name: String) throws {
        let row = try summary(name: name)
        #expect(row.displayName == "Classic Chrome #7")
        #expect(row.accessibilityLabel == "Classic Chrome #7, Classic Chrome")
        #expect(try summary(name: name, isFavorite: true).accessibilityLabel
            == "Classic Chrome #7, Classic Chrome, favourite")
    }
}
