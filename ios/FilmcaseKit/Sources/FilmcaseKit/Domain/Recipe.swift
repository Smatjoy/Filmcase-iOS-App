// Mirrors: the FujifilmRecipeData shape served by RecipeCameraPayload
// (src/interfaces/camera/views.py) and consumed by the JS client
// (domain/validation.js, domain/queries.js; fetched by vendor/recipe_payload.js).

import Foundation

/// A recipe in the shape the camera write path consumes.
///
/// Numeric fields travel as strings, exactly as served ("+1.5", "-2", "6500K" for white
/// balance), because validation and conversion parse them the way Python does. Optional
/// fields are `nil` when the server sends `null` or omits them.
public struct Recipe: Codable, Equatable, Sendable {
    public var name: String
    public var filmSimulation: String
    public var dRangePriority: String
    public var grainRoughness: String
    public var colorChromeEffect: String
    public var colorChromeFxBlue: String
    public var whiteBalance: String
    public var whiteBalanceRed: Int
    public var whiteBalanceBlue: Int
    public var sharpness: String
    public var highIsoNr: String
    public var clarity: String
    public var dynamicRange: String?
    public var grainSize: String?
    public var highlight: String?
    public var shadow: String?
    public var color: String?
    public var monochromaticColorWarmCool: String?
    public var monochromaticColorMagentaGreen: String?
    public var sensors: [String]
    public var description: String

    public init(
        name: String,
        filmSimulation: String,
        dRangePriority: String = "Off",
        grainRoughness: String = "Off",
        colorChromeEffect: String = "Off",
        colorChromeFxBlue: String = "Off",
        whiteBalance: String = "Auto",
        whiteBalanceRed: Int = 0,
        whiteBalanceBlue: Int = 0,
        sharpness: String = "0",
        highIsoNr: String = "0",
        clarity: String = "0",
        dynamicRange: String? = nil,
        grainSize: String? = nil,
        highlight: String? = nil,
        shadow: String? = nil,
        color: String? = nil,
        monochromaticColorWarmCool: String? = nil,
        monochromaticColorMagentaGreen: String? = nil,
        sensors: [String] = [],
        description: String = ""
    ) {
        self.name = name
        self.filmSimulation = filmSimulation
        self.dRangePriority = dRangePriority
        self.grainRoughness = grainRoughness
        self.colorChromeEffect = colorChromeEffect
        self.colorChromeFxBlue = colorChromeFxBlue
        self.whiteBalance = whiteBalance
        self.whiteBalanceRed = whiteBalanceRed
        self.whiteBalanceBlue = whiteBalanceBlue
        self.sharpness = sharpness
        self.highIsoNr = highIsoNr
        self.clarity = clarity
        self.dynamicRange = dynamicRange
        self.grainSize = grainSize
        self.highlight = highlight
        self.shadow = shadow
        self.color = color
        self.monochromaticColorWarmCool = monochromaticColorWarmCool
        self.monochromaticColorMagentaGreen = monochromaticColorMagentaGreen
        self.sensors = sensors
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case name
        case filmSimulation = "film_simulation"
        case dRangePriority = "d_range_priority"
        case grainRoughness = "grain_roughness"
        case colorChromeEffect = "color_chrome_effect"
        case colorChromeFxBlue = "color_chrome_fx_blue"
        case whiteBalance = "white_balance"
        case whiteBalanceRed = "white_balance_red"
        case whiteBalanceBlue = "white_balance_blue"
        case sharpness
        case highIsoNr = "high_iso_nr"
        case clarity
        case dynamicRange = "dynamic_range"
        case grainSize = "grain_size"
        case highlight
        case shadow
        case color
        case monochromaticColorWarmCool = "monochromatic_color_warm_cool"
        case monochromaticColorMagentaGreen = "monochromatic_color_magenta_green"
        case sensors
        case description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        filmSimulation = try c.decode(String.self, forKey: .filmSimulation)
        dRangePriority = try c.decode(String.self, forKey: .dRangePriority)
        grainRoughness = try c.decode(String.self, forKey: .grainRoughness)
        colorChromeEffect = try c.decode(String.self, forKey: .colorChromeEffect)
        colorChromeFxBlue = try c.decode(String.self, forKey: .colorChromeFxBlue)
        whiteBalance = try c.decode(String.self, forKey: .whiteBalance)
        whiteBalanceRed = try c.decode(Int.self, forKey: .whiteBalanceRed)
        whiteBalanceBlue = try c.decode(Int.self, forKey: .whiteBalanceBlue)
        sharpness = try c.decode(String.self, forKey: .sharpness)
        highIsoNr = try c.decode(String.self, forKey: .highIsoNr)
        clarity = try c.decode(String.self, forKey: .clarity)
        dynamicRange = try c.decodeIfPresent(String.self, forKey: .dynamicRange)
        grainSize = try c.decodeIfPresent(String.self, forKey: .grainSize)
        highlight = try c.decodeIfPresent(String.self, forKey: .highlight)
        shadow = try c.decodeIfPresent(String.self, forKey: .shadow)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        monochromaticColorWarmCool = try c.decodeIfPresent(String.self, forKey: .monochromaticColorWarmCool)
        monochromaticColorMagentaGreen = try c.decodeIfPresent(String.self, forKey: .monochromaticColorMagentaGreen)
        sensors = try c.decodeIfPresent([String].self, forKey: .sensors) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}
