// The recipe form as the API serves and takes it: `GET /api/v1/recipes/form-options/`,
// `GET /api/v1/recipes/<id>/form/`, and the JSON body of create, edit and new version.

import Foundation

/// The lowest and highest values of a number field, and the step between them.
public struct RecipeFieldRange: Decodable, Sendable, Equatable {
    public let min: Double
    public let max: Double
    public let step: Double

    public init(min: Double, max: Double, step: Double) {
        self.min = min
        self.max = max
        self.step = step
    }
}

/// What the editor offers, from the same form the browser uses.
public struct RecipeFormOptions: Decodable, Sendable, Equatable {
    /// Field name (`film_simulation`) to its choices, in the form's order.
    public let choices: [String: [String]]
    public let ranges: [String: RecipeFieldRange]
    public let monochromaticFilmSimulations: [String]

    enum CodingKeys: String, CodingKey {
        case choices, ranges
        case monochromaticFilmSimulations = "monochromatic_film_simulations"
    }
}

/// A recipe's editable values. Field names match the server's form.
public struct RecipeDraft: Codable, Sendable, Equatable {
    public var name = ""
    public var filmSimulation = "Provia"
    public var dynamicRange: String? = "DR100"
    public var dRangePriority = "Off"
    public var grainRoughness = "Off"
    public var grainSize: String? = "Off"
    public var colorChromeEffect = "Off"
    public var colorChromeFxBlue = "Off"
    public var whiteBalance = "Auto"
    public var kelvinTemperature: Int?
    public var whiteBalanceRed = 0
    public var whiteBalanceBlue = 0
    public var highlight: Double? = 0
    public var shadow: Double? = 0
    public var color: Int? = 0
    public var sharpness = 0
    public var highIsoNr = 0
    public var clarity = 0
    public var monochromaticColorWarmCool: Double?
    public var monochromaticColorMagentaGreen: Double?
    public var sensors: [String] = []
    public var description = ""

    public init() {}

    enum CodingKeys: String, CodingKey {
        case name, highlight, shadow, color, sharpness, clarity, sensors, description
        case filmSimulation = "film_simulation"
        case dynamicRange = "dynamic_range"
        case dRangePriority = "d_range_priority"
        case grainRoughness = "grain_roughness"
        case grainSize = "grain_size"
        case colorChromeEffect = "color_chrome_effect"
        case colorChromeFxBlue = "color_chrome_fx_blue"
        case whiteBalance = "white_balance"
        case kelvinTemperature = "kelvin_temperature"
        case whiteBalanceRed = "white_balance_red"
        case whiteBalanceBlue = "white_balance_blue"
        case highIsoNr = "high_iso_nr"
        case monochromaticColorWarmCool = "monochromatic_color_warm_cool"
        case monochromaticColorMagentaGreen = "monochromatic_color_magenta_green"
    }
}

/// `GET /api/v1/recipes/<id>/form/`.
public struct RecipeFormValues: Decodable, Sendable, Equatable {
    /// False for a recipe with images: only its name and description can change.
    public let isEditable: Bool
    public let hasVersionLine: Bool
    public let values: RecipeDraft

    enum CodingKeys: String, CodingKey {
        case values
        case isEditable = "is_editable"
        case hasVersionLine = "has_version_line"
    }
}

/// The name and description alone, for a recipe whose settings cannot change.
public struct RecipeLabels: Encodable, Sendable, Equatable {
    public let name: String
    public let description: String
}

/// The body of a collection write. Recipes keep the order given.
public struct CollectionFields: Encodable, Sendable, Equatable {
    public let name: String
    public let recipeIDs: [Int]

    public init(name: String, recipeIDs: [Int]) {
        self.name = name
        self.recipeIDs = recipeIDs
    }

    enum CodingKeys: String, CodingKey {
        case name
        case recipeIDs = "recipe_ids"
    }
}

/// The body of a write that created something.
struct CreatedID: Decodable {
    let id: Int
}
