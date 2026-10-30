// Mirrors: the write path of src/domain/camera/queries.py (RecipePTPValues,
// recipe_to_ptp_values, custom_slot_count) and src/interfaces/static/js/camera/domain/queries.js
// (recipeToPtpValues, ptpValueItems, customSlotCount). The read path stays on the server.

import Foundation

/// Raised when validation passed but a value cannot be converted (a table the served
/// encodings lack, or a numeric field Python's `int()`/`float()` would also refuse).
public enum RecipeConversionError: Error, Equatable, Sendable {
    case missingEncoding(String)
    case notANumber(field: String, value: String)
}

/// One `(property code, encoded value)` pair to write.
public struct PTPValueItem: Equatable, Sendable {
    public let code: UInt16
    public let value: Int

    public init(code: UInt16, value: Int) {
        self.code = code
        self.value = value
    }
}

/// PTP integer values to write for each custom-slot property. Property names mirror the
/// keys of `custom_slot_codes`. `nil` means "not applicable to this recipe" and is not
/// written (DRangeMode when D-Range Priority is active, colour on a monochrome simulation,
/// the toning axes on a colour one).
public struct RecipePTPValues: Equatable, Sendable {
    public var filmSimulation: Int
    public var whiteBalance: Int
    public var whiteBalanceColorTemperature: Int?
    public var whiteBalanceRed: Int
    public var whiteBalanceBlue: Int
    public var dRangeMode: Int?
    public var dRangePriority: Int
    public var grainEffect: Int
    public var colorEffect: Int
    public var colorFx: Int
    public var colorMode: Int?
    public var sharpness: Int
    public var highLightTone: Int?
    public var shadowTone: Int?
    public var highIsoNoiseReduction: Int
    public var definition: Int
    public var monochromaticColorWarmCool: Int?
    public var monochromaticColorMagentaGreen: Int?

    /// The value for a property name as it appears in `custom_slot_codes` / `write_order`.
    public func value(forProperty name: String) -> Int? {
        switch name {
        case "FilmSimulation": return filmSimulation
        case "WhiteBalance": return whiteBalance
        case "WhiteBalanceColorTemperature": return whiteBalanceColorTemperature
        case "WhiteBalanceRed": return whiteBalanceRed
        case "WhiteBalanceBlue": return whiteBalanceBlue
        case "DRangeMode": return dRangeMode
        case "DRangePriority": return dRangePriority
        case "GrainEffect": return grainEffect
        case "ColorEffect": return colorEffect
        case "ColorFx": return colorFx
        case "ColorMode": return colorMode
        case "Sharpness": return sharpness
        case "HighLightTone": return highLightTone
        case "ShadowTone": return shadowTone
        case "HighIsoNoiseReduction": return highIsoNoiseReduction
        case "Definition": return definition
        case "MonochromaticColorWarmCool": return monochromaticColorWarmCool
        case "MonochromaticColorMagentaGreen": return monochromaticColorMagentaGreen
        default: return nil
        }
    }
}

/// True when a field carries no value, as opposed to a value of zero.
private func isAbsent(_ value: String?) -> Bool { value == nil || value == "" }

private func isAbsentOrNA(_ value: String?) -> Bool { isAbsent(value) || value == "N/A" }

/// Integer field scaled by ten.
private func scaleInt(_ value: String, field: String) throws -> Int {
    guard let parsed = parseStrictInt(value) else {
        throw RecipeConversionError.notANumber(field: field, value: value)
    }
    return parsed * 10
}

/// Half-step field: value times ten, rounded. Python rounds half to even and so does this.
private func scaleDecimal(_ value: String, field: String) throws -> Int {
    guard let parsed = parseStrictDouble(value) else {
        throw RecipeConversionError.notANumber(field: field, value: value)
    }
    return Int((parsed * 10).rounded(.toNearestOrEven))
}

private func scaledInt(_ value: String?, field: String, naIsAbsent: Bool) throws -> Int? {
    guard let value, !(naIsAbsent ? isAbsentOrNA(value) : isAbsent(value)) else { return nil }
    return try scaleInt(value, field: field)
}

private func scaledDecimal(_ value: String?, field: String) throws -> Int? {
    guard let value, !isAbsent(value) else { return nil }
    return try scaleDecimal(value, field: field)
}

private func required(_ value: Int?, _ table: String) throws -> Int {
    guard let value else { throw RecipeConversionError.missingEncoding(table) }
    return value
}

/// Convert a recipe into PTP values, validating it first so an invalid recipe cannot reach
/// the camera by any route.
public func recipeToPtpValues(_ recipe: Recipe, encodings: ClientEncodings) throws -> RecipePTPValues {
    try validateRecipeForCamera(recipe, encodings: encodings)

    let filmSim = try required(encodings.filmSimulationToPtp[recipe.filmSimulation], "film_simulation_to_ptp")

    // --- white balance: a named mode, or a colour temperature like "6500K" ---
    let wbLabel = recipe.whiteBalance
    let wb: Int
    var wbKelvin: Int?
    let kelvinDigits = wbLabel.dropLast()
    if wbLabel.hasSuffix("K"), !kelvinDigits.isEmpty, kelvinDigits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
        wb = try required(encodings.whiteBalanceToPtp["Kelvin"], "white_balance_to_ptp")
        wbKelvin = try required(Int(kelvinDigits), "white_balance kelvin")
    } else {
        wb = try required(encodings.whiteBalanceToPtp[wbLabel], "white_balance_to_ptp")
    }

    // --- D-Range Priority (always written; anything unrecognised means Off) ---
    let drp = recipe.dRangePriority
    let drPriority = try required(encodings.drPriorityToPtp[drp] ?? encodings.drPriorityToPtp["Off"], "dr_priority_to_ptp")

    // --- D-Range mode: priority wins, so the mode is not written when it is on ---
    var drMode: Int?
    if drp.isEmpty || drp == "Off" {
        if let dr = recipe.dynamicRange, !dr.isEmpty { drMode = encodings.drangeModeToPtp[dr] }
    }

    // --- grain (always written) ---
    let grain: Int
    if recipe.grainRoughness == "Off" {
        grain = encodings.grainOffSentinel
    } else {
        grain = try required(recipe.grainSize.flatMap { encodings.grainToPtp[recipe.grainRoughness]?[$0] }, "grain_to_ptp")
    }

    // --- colour chrome effect / FX blue (always written; unset means Off) ---
    let cce = try required(encodings.cceToPtp[recipe.colorChromeEffect] ?? encodings.cceToPtp["Off"], "cce_to_ptp")
    let cfx = try required(encodings.cfxToPtp[recipe.colorChromeFxBlue] ?? encodings.cfxToPtp["Off"], "cfx_to_ptp")

    // --- scaled fields ---
    // Colour tests only for absence, not "N/A", as the Python does; sharpness and clarity
    // test for both.
    let color = try scaledInt(recipe.color, field: "color", naIsAbsent: false)
    let sharpness = try scaledInt(recipe.sharpness, field: "sharpness", naIsAbsent: true) ?? 0
    let clarity = try scaledInt(recipe.clarity, field: "clarity", naIsAbsent: true) ?? 0
    let highlight = try scaledDecimal(recipe.highlight, field: "highlight")
    let shadow = try scaledDecimal(recipe.shadow, field: "shadow")

    // --- high ISO noise reduction (non-linear; unset means 0/normal) ---
    var nrDomain = 0
    if !isAbsentOrNA(recipe.highIsoNr) {
        guard let parsed = parseStrictInt(recipe.highIsoNr) else {
            throw RecipeConversionError.notANumber(field: "high_iso_nr", value: recipe.highIsoNr)
        }
        nrDomain = parsed
    }
    let nr = try required(encodings.nrToPtp[nrDomain], "nr_to_ptp")

    // --- monochrome toning, only present on a monochrome simulation ---
    let warmCool = try scaledDecimal(recipe.monochromaticColorWarmCool, field: "monochromatic_color_warm_cool")
    let magentaGreen = try scaledDecimal(recipe.monochromaticColorMagentaGreen, field: "monochromatic_color_magenta_green")

    return RecipePTPValues(
        filmSimulation: filmSim,
        whiteBalance: wb,
        whiteBalanceColorTemperature: wbKelvin,
        whiteBalanceRed: recipe.whiteBalanceRed,
        whiteBalanceBlue: recipe.whiteBalanceBlue,
        dRangeMode: drMode,
        dRangePriority: drPriority,
        grainEffect: grain,
        colorEffect: cce,
        colorFx: cfx,
        colorMode: color,
        sharpness: sharpness,
        highLightTone: highlight,
        shadowTone: shadow,
        highIsoNoiseReduction: nr,
        definition: clarity,
        monochromaticColorWarmCool: warmCool,
        monochromaticColorMagentaGreen: magentaGreen
    )
}

/// `RecipePTPValues.items()` / JS `ptpValueItems`: `(code, value)` for every set property,
/// in the server's `write_order` (colour temperature must precede the two shifts, or the
/// camera zeroes them when the temperature lands).
public func ptpValueItems(_ values: RecipePTPValues, encodings: ClientEncodings) -> [PTPValueItem] {
    encodings.writeOrder.compactMap { name in
        guard let value = values.value(forProperty: name), let code = encodings.customSlotCodes[name] else {
            return nil
        }
        return PTPValueItem(code: UInt16(truncatingIfNeeded: code), value: value)
    }
}

/// `custom_slot_count`: slots a camera model offers; 0 for an unknown model.
public func customSlotCount(cameraName: String, encodings: ClientEncodings) -> Int {
    encodings.cameraCustomSlotCounts[cameraName] ?? 0
}
