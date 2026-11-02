// Apple-only. Thin adapter: FilmcaseKit's RecipeLookup finds and ranks recipes.

import AppIntents  // API: AppEntity, EntityStringQuery, DisplayRepresentation, TypeDisplayRepresentation
import FilmcaseKit

struct RecipeEntity: AppEntity {
    // API: AppEntity.typeDisplayRepresentation / defaultQuery are static requirements
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recipe"
    static let defaultQuery = RecipeEntityQuery()

    // API: AppEntity.id (Int is EntityIdentifierConvertible)
    let id: Int
    let name: String
    let subtitle: String

    init(_ summary: RecipeEntitySummary) {
        self.id = summary.id
        self.name = summary.name
        self.subtitle = summary.subtitle
    }

    // API: DisplayRepresentation(title:subtitle:) with interpolated LocalizedStringResource
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }
}

struct RecipeEntityQuery: EntityStringQuery {
    func entities(for identifiers: [Int]) async throws -> [RecipeEntity] {
        guard let lookup = await AppEnvironment.sharedRecipeLookup() else { return [] }
        return try await lookup.recipes(withIDs: identifiers).map(RecipeEntity.init)
    }

    func entities(matching string: String) async throws -> [RecipeEntity] {
        guard let lookup = await AppEnvironment.sharedRecipeLookup() else { return [] }
        return try await lookup.search(name: string).map(RecipeEntity.init)
    }

    func suggestedEntities() async throws -> [RecipeEntity] {
        guard let lookup = await AppEnvironment.sharedRecipeLookup() else { return [] }
        return try await lookup.suggested().map(RecipeEntity.init)
    }
}
