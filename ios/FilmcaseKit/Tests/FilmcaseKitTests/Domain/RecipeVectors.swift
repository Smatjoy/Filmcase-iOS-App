// Loads tests/fixtures/camera/recipe_ptp_vectors.json, the golden vectors shared with
// tests/js/queries.test.js, tests/js/validation.test.js and
// tests/unit/domain/camera/test_recipe_ptp_vectors.py. Read from the repo in place.

import Foundation
import Testing
@testable import FilmcaseKit

enum JSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.foundation)
        case .object(let v): return v.mapValues(\.foundation)
        }
    }
}

struct RecipeItemVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let why: String
    let recipe: Recipe
    let expected_items: [[Int]]
    var testDescription: String { name }
}

struct ValidationVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let overrides: [String: JSONValue]
    let expected: String
    var testDescription: String { name }
}

struct RecipePtpVectors: Decodable, Sendable {
    let encodings: ClientEncodings
    let vectors: [RecipeItemVector]
    let validation_vectors: [ValidationVector]

    /// repo root / tests/fixtures/camera/recipe_ptp_vectors.json, resolved from this file's path.
    static func fixtureURL(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        // file -> Domain -> FilmcaseKitTests -> Tests -> FilmcaseKit -> ios -> repo root
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("tests/fixtures/camera/recipe_ptp_vectors.json")
    }

    static func load() throws -> RecipePtpVectors {
        try JSONDecoder().decode(RecipePtpVectors.self, from: Data(contentsOf: fixtureURL()))
    }

    /// Never throws, so it can feed `@Test(arguments:)`; a load failure yields empty
    /// vector lists, which the presence test turns into a failure.
    static let shared: RecipePtpVectors? = try? load()

    static var sharedVectors: [RecipeItemVector] { shared?.vectors ?? [] }
    static var sharedValidation: [ValidationVector] { shared?.validation_vectors ?? [] }

    /// `makeRecipe(overrides)` from tests/js/fakes/vectors.js: the `named_white_balance`
    /// recipe with the overrides laid on top (JSON null clears a field).
    func recipe(overrides: [String: JSONValue]) throws -> Recipe {
        guard let base = vectors.first(where: { $0.name == "named_white_balance" }) else {
            throw VectorError.missingBase
        }
        let encoded = try JSONEncoder().encode(base.recipe)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, value) in overrides { object[key] = value.foundation }
        return try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

enum VectorError: Error { case missingBase }
