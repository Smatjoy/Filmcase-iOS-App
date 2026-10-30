// Decodes exactly what src/interfaces/api/views.py emits. Keys are mapped with
// explicit CodingKeys, not a key strategy: facet names are dictionary keys and
// must not be rewritten.

import Foundation

/// `{"position": 2, "label": "v2"}`: a recipe's place in its version line.
public struct RecipeVersion: Decodable, Sendable, Equatable {
    public let position: Int
    public let label: String
}

/// One row of the recipe list.
public struct RecipeSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let filmSimulation: String
    public let dynamicRange: String
    public let grainRoughness: String
    public let colorChromeEffect: String
    public let whiteBalance: String
    public let imageCount: Int
    /// True when any image taken with the recipe is a favourite.
    public let isFavorite: Bool
    public let version: RecipeVersion?
    public let coverThumbnailURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, version
        case filmSimulation = "film_simulation"
        case dynamicRange = "dynamic_range"
        case grainRoughness = "grain_roughness"
        case colorChromeEffect = "color_chrome_effect"
        case whiteBalance = "white_balance"
        case imageCount = "image_count"
        case isFavorite = "is_favorite"
        case coverThumbnailURL = "cover_thumbnail_url"
    }
}

public struct FacetOption: Decodable, Sendable, Equatable {
    public let value: String
    /// Only sent for the sensor facet, where the value is not human readable.
    public let label: String?
    public let count: Int
    public let available: Bool
    public let selected: Bool
}

/// One filter section of the explorer sidebar.
public struct Facet: Decodable, Sendable, Equatable {
    public let label: String
    public let options: [FacetOption]
    public let selected: [String]
}

/// `GET /api/v1/recipes/`. `next` and `previous` are server-relative links.
public struct RecipePage: Decodable, Sendable, Equatable {
    public let count: Int
    public let next: String?
    public let previous: String?
    public let results: [RecipeSummary]
    public let facets: [String: Facet]
}

public struct VersionLineEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let position: Int
    public let label: String
    public let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, position, label
        case isCurrent = "is_current"
    }
}

/// A collection a recipe belongs to, as listed in the recipe detail.
public struct CollectionReference: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let recipeCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case recipeCount = "recipe_count"
    }
}

/// `GET /api/v1/recipes/<id>/`. Numeric settings are JSON numbers, or null when unused.
public struct RecipeDetail: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let description: String
    public let filmSimulation: String
    public let dynamicRange: String
    public let dRangePriority: String
    public let grainRoughness: String
    public let grainSize: String
    public let colorChromeEffect: String
    public let colorChromeFXBlue: String
    public let whiteBalance: String
    public let whiteBalanceRed: Int
    public let whiteBalanceBlue: Int
    public let highlight: Double?
    public let shadow: Double?
    public let color: Double?
    public let sharpness: Double?
    public let highISONR: Double?
    public let clarity: Double?
    public let monochromaticColorWarmCool: Double?
    public let monochromaticColorMagentaGreen: Double?
    public let isMonochromatic: Bool
    public let sensors: [String]
    public let bodies: [String]
    public let imageCount: Int
    public let isFavorite: Bool
    public let version: RecipeVersion?
    public let versionLine: [VersionLineEntry]
    public let collections: [CollectionReference]
    public let coverImageURL: String?
    public let coverThumbnailURL: String?
    public let cameraPayloadURL: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, highlight, shadow, color, sharpness, clarity
        case sensors, bodies, version, collections
        case filmSimulation = "film_simulation"
        case dynamicRange = "dynamic_range"
        case dRangePriority = "d_range_priority"
        case grainRoughness = "grain_roughness"
        case grainSize = "grain_size"
        case colorChromeEffect = "color_chrome_effect"
        case colorChromeFXBlue = "color_chrome_fx_blue"
        case whiteBalance = "white_balance"
        case whiteBalanceRed = "white_balance_red"
        case whiteBalanceBlue = "white_balance_blue"
        case highISONR = "high_iso_nr"
        case monochromaticColorWarmCool = "monochromatic_color_warm_cool"
        case monochromaticColorMagentaGreen = "monochromatic_color_magenta_green"
        case isMonochromatic = "is_monochromatic"
        case imageCount = "image_count"
        case isFavorite = "is_favorite"
        case versionLine = "version_line"
        case coverImageURL = "cover_image_url"
        case coverThumbnailURL = "cover_thumbnail_url"
        case cameraPayloadURL = "camera_payload_url"
    }
}

public struct CollectionSummary: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let recipeCount: Int
    public let filmSimulations: [String]
    public let coverThumbnailURLs: [String?]

    enum CodingKeys: String, CodingKey {
        case id, name
        case recipeCount = "recipe_count"
        case filmSimulations = "film_simulations"
        case coverThumbnailURLs = "cover_thumbnail_urls"
    }
}

/// `GET /api/v1/collections/`. Not paginated.
public struct CollectionList: Decodable, Sendable, Equatable {
    public let count: Int
    public let results: [CollectionSummary]
}

public struct CollectionMember: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let filmSimulation: String
    public let imageCount: Int
    public let position: Int

    enum CodingKeys: String, CodingKey {
        case id, name, position
        case filmSimulation = "film_simulation"
        case imageCount = "image_count"
    }
}

/// `GET /api/v1/collections/<id>/`: recipes in stored order.
public struct CollectionDetail: Decodable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let recipeIDs: [Int]
    public let recipes: [CollectionMember]

    enum CodingKeys: String, CodingKey {
        case id, name, recipes
        case recipeIDs = "recipe_ids"
    }
}

/// `{"error": "..."}`, the body of every non-2xx JSON answer.
public struct APIErrorBody: Decodable, Sendable, Equatable {
    public let error: String
}
