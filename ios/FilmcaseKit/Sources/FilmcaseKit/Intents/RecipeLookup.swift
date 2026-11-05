// What an App Intents `EntityQuery` needs about recipes: find by id, find by name, and a
// short list to suggest. The adapter maps `RecipeEntitySummary` to its `AppEntity`.

import Foundation

/// The rule for a recipe that cannot be sent. Mirrors RecipeDetailModel's wording (a test pins
/// that the two stay equal).
public enum RecipeSendRule {
    public static let unnamedReason = "Name this recipe before sending it to a camera."

    /// A slot needs a name, so a blank one cannot be sent.
    public static func isUnnamed(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A recipe as an entity query returns it.
public struct RecipeEntitySummary: Equatable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let filmSimulation: String
    public let isFavorite: Bool
    /// Images taken with the recipe, a stand-in for "most used".
    public let imageCount: Int

    /// False for an unnamed recipe, which cannot be sent to a camera.
    public var isSendable: Bool { !RecipeSendRule.isUnnamed(name) }
    /// For the entity's subtitle.
    public var subtitle: String { filmSimulation }

    public init(id: Int, name: String, filmSimulation: String, isFavorite: Bool, imageCount: Int) {
        self.id = id
        self.name = name
        self.filmSimulation = filmSimulation
        self.isFavorite = isFavorite
        self.imageCount = imageCount
    }

    init(_ summary: RecipeSummary) {
        self.init(
            id: summary.id, name: summary.name, filmSimulation: summary.filmSimulation,
            isFavorite: summary.isFavorite, imageCount: summary.imageCount)
    }

    init(_ detail: RecipeDetail) {
        self.init(
            id: detail.id, name: detail.name, filmSimulation: detail.filmSimulation,
            isFavorite: detail.isFavorite, imageCount: detail.imageCount)
    }
}

public struct RecipeLookup: Sendable {
    /// The most suggestions (and search results) returned.
    public static let suggestionLimit = 20
    private static let fetchSize = 50

    private let client: FilmcaseClient

    public init(client: FilmcaseClient) {
        self.client = client
    }

    /// The recipes with these ids, in the order asked. A recipe the server does not know is
    /// left out. Unnamed recipes are included (flagged by `isSendable`) so a Shortcut that holds
    /// one can still say why it cannot be sent.
    public func recipes(withIDs ids: [Int]) async throws -> [RecipeEntitySummary] {
        var found: [RecipeEntitySummary] = []
        for id in ids {
            do {
                found.append(RecipeEntitySummary(try await client.recipe(id: id)))
            } catch FilmcaseClientError.notFound {
                continue
            }
        }
        return found
    }

    /// Sendable recipes whose name matches *text*, in the server's order. Blank text gives the
    /// suggestions.
    public func search(name text: String, limit: Int = RecipeLookup.suggestionLimit) async throws -> [RecipeEntitySummary] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await suggested(limit: limit) }
        let page = try await client.recipes(
            pageSize: Self.fetchSize, filters: RecipeFilters(nameSearch: trimmed))
        return Array(page.results.map(RecipeEntitySummary.init).filter(\.isSendable).prefix(limit))
    }

    /// Favourites first, then the most used, never more than *limit* and never an unnamed
    /// recipe.
    public func suggested(limit: Int = RecipeLookup.suggestionLimit) async throws -> [RecipeEntitySummary] {
        let favourites = try await client.recipes(pageSize: Self.fetchSize, favoritesOnly: true)
        var chosen = Self.mostUsedFirst(favourites.results.map(RecipeEntitySummary.init).filter(\.isSendable))
        if chosen.count < limit {
            let all = try await client.recipes(pageSize: Self.fetchSize)
            let taken = Set(chosen.map(\.id))
            chosen += Self.mostUsedFirst(
                all.results.map(RecipeEntitySummary.init).filter { $0.isSendable && !taken.contains($0.id) })
        }
        return Array(chosen.prefix(limit))
    }

    /// Most images first; recipes with the same count keep the server's order.
    static func mostUsedFirst(_ recipes: [RecipeEntitySummary]) -> [RecipeEntitySummary] {
        recipes.enumerated()
            .sorted { ($0.element.imageCount, $1.offset) > ($1.element.imageCount, $0.offset) }
            .map(\.element)
    }
}
