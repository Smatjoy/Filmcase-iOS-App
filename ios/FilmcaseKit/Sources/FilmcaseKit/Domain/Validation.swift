// Mirrors: src/domain/camera/validation.py and src/interfaces/static/js/camera/domain/validation.js
// Same checks in the same order, so the same recipe is rejected for the same field.

import Foundation

/// Raised when a field holds a value the camera cannot accept.
public struct RecipeValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let field: String
    /// The offending value rendered as Python's repr would (`'x'`, `None`, `('Weak', None)`).
    public let value: String

    public init(field: String, value: String) {
        self.field = field
        self.value = value
    }

    public var description: String { "Invalid value for field '\(field)': \(value)" }
}

private let emptyOrNA: Set<String> = ["", "N/A"]

func repr(_ value: String?) -> String {
    guard let value else { return "None" }
    return "'\(value)'"
}

private func isAbsent(_ value: String?) -> Bool { value == nil || value == "" }

private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

/// `^\d+K$` over ASCII digits.
private func isKelvin(_ text: String) -> Bool {
    guard text.hasSuffix("K") else { return false }
    let digits = text.dropLast()
    return !digits.isEmpty && digits.utf8.allSatisfy(isDigit)
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Parses the way Python's `int()` does (optional sign, ASCII digits), rejecting "1.5".
/// Returns nil on a non-integer; values beyond `Int` also return nil.
func parseStrictInt(_ value: String) -> Int? {
    let text = trimmed(value)
    var digits = Substring(text)
    if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
    guard !digits.isEmpty, digits.utf8.allSatisfy(isDigit) else { return nil }
    return Int(text)
}

/// Syntax check for `int()` without the range limit.
private func isIntSyntax(_ value: String) -> Bool {
    var digits = Substring(trimmed(value))
    if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
    return !digits.isEmpty && digits.utf8.allSatisfy(isDigit)
}

/// Parses the way Python's `float()` does for decimal notation: optional sign, digits with
/// optional point, optional exponent. Rejects "", hex, "nan" and "inf".
func parseStrictDouble(_ value: String) -> Double? {
    let text = trimmed(value)
    var bytes = Array(text.utf8)[...]
    if let first = bytes.first, first == 0x2B || first == 0x2D { bytes = bytes.dropFirst() }
    var intDigits = 0
    while let b = bytes.first, isDigit(b) { intDigits += 1; bytes = bytes.dropFirst() }
    var fracDigits = 0
    if bytes.first == 0x2E {
        bytes = bytes.dropFirst()
        while let b = bytes.first, isDigit(b) { fracDigits += 1; bytes = bytes.dropFirst() }
    }
    guard intDigits + fracDigits > 0 else { return nil }
    if let e = bytes.first, e == 0x65 || e == 0x45 {
        bytes = bytes.dropFirst()
        if let s = bytes.first, s == 0x2B || s == 0x2D { bytes = bytes.dropFirst() }
        var expDigits = 0
        while let b = bytes.first, isDigit(b) { expDigits += 1; bytes = bytes.dropFirst() }
        guard expDigits > 0 else { return nil }
    }
    guard bytes.isEmpty, let parsed = Double(text), parsed.isFinite else { return nil }
    return parsed
}

private func validateIntStr(_ value: String?, field: String) throws {
    guard let value, !emptyOrNA.contains(value) else { return }
    if !isIntSyntax(value) { throw RecipeValidationError(field: field, value: repr(value)) }
}

private func validateFloatStr(_ value: String?, field: String) throws {
    guard let value, !emptyOrNA.contains(value) else { return }
    if parseStrictDouble(value) == nil { throw RecipeValidationError(field: field, value: repr(value)) }
}

/// `validate_recipe_for_profile`: throws on the first field that fails.
public func validateRecipeForProfile(_ recipe: Recipe, profile: CameraProfile) throws {
    // --- name: required; non-blank ASCII within the length limit ---
    let name = recipe.name
    if name.isEmpty || trimmed(name).isEmpty {
        throw RecipeValidationError(field: "name", value: repr(name))
    }
    if name.unicodeScalars.count > profile.recipeNameMaxLen {
        throw RecipeValidationError(field: "name", value: repr(name))
    }
    if !name.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
        throw RecipeValidationError(field: "name", value: repr(name))
    }

    // --- film_simulation ---
    if !profile.supportedFilmSimulations.contains(recipe.filmSimulation) {
        throw RecipeValidationError(field: "film_simulation", value: repr(recipe.filmSimulation))
    }

    // --- white_balance: a named mode or a Kelvin string ---
    let wb = recipe.whiteBalance
    if !profile.supportedWhiteBalanceModes.contains(wb) && !isKelvin(wb) {
        throw RecipeValidationError(field: "white_balance", value: repr(wb))
    }

    // --- dynamic_range: absent is fine; "N/A" is not a dynamic range ---
    if !isAbsent(recipe.dynamicRange), let dr = recipe.dynamicRange {
        if !profile.supportedDynamicRanges.contains(dr) {
            throw RecipeValidationError(field: "dynamic_range", value: repr(dr))
        }
    }

    // --- d_range_priority ---
    if !emptyOrNA.contains(recipe.dRangePriority)
        && !profile.supportedDrPriorities.contains(recipe.dRangePriority)
    {
        throw RecipeValidationError(field: "d_range_priority", value: repr(recipe.dRangePriority))
    }

    // --- grain: roughness and size validated together ---
    let roughness = recipe.grainRoughness
    let size = recipe.grainSize
    let grainPair = "(\(repr(roughness)), \(repr(size)))"
    if !profile.supportedGrainRoughnesses.contains(roughness) {
        throw RecipeValidationError(field: "grain_roughness", value: grainPair)
    }
    if let size, size != "" {
        let valid = roughness == "Off" ? profile.grainSizesWhenOff : profile.grainSizesWhenOn
        if !valid.contains(size) {
            throw RecipeValidationError(field: "grain_roughness", value: grainPair)
        }
    } else if roughness != "Off" {
        throw RecipeValidationError(field: "grain_roughness", value: grainPair)
    }

    // --- colour chrome effect / FX blue ---
    if !emptyOrNA.contains(recipe.colorChromeEffect)
        && !profile.supportedColorChromeEffects.contains(recipe.colorChromeEffect)
    {
        throw RecipeValidationError(field: "color_chrome_effect", value: repr(recipe.colorChromeEffect))
    }
    if !emptyOrNA.contains(recipe.colorChromeFxBlue)
        && !profile.supportedColorChromeFxBlues.contains(recipe.colorChromeFxBlue)
    {
        throw RecipeValidationError(field: "color_chrome_fx_blue", value: repr(recipe.colorChromeFxBlue))
    }

    // --- high ISO NR: an integer the non-linear table knows ---
    if !emptyOrNA.contains(recipe.highIsoNr) {
        guard let nr = parseStrictInt(recipe.highIsoNr), profile.supportedHighIsoNrValues.contains(nr) else {
            throw RecipeValidationError(field: "high_iso_nr", value: repr(recipe.highIsoNr))
        }
    }

    // --- numeric string fields ---
    try validateIntStr(recipe.color, field: "color")
    try validateIntStr(recipe.sharpness, field: "sharpness")
    try validateIntStr(recipe.clarity, field: "clarity")
    try validateFloatStr(recipe.highlight, field: "highlight")
    try validateFloatStr(recipe.shadow, field: "shadow")
    try validateFloatStr(recipe.monochromaticColorWarmCool, field: "monochromatic_color_warm_cool")
    try validateFloatStr(recipe.monochromaticColorMagentaGreen, field: "monochromatic_color_magenta_green")
}

/// `validate_recipe_for_camera` / JS `validateRecipeForCamera`: validate against the
/// per-property profile derived from the served encodings.
public func validateRecipeForCamera(_ recipe: Recipe, encodings: ClientEncodings) throws {
    try validateRecipeForProfile(recipe, profile: .perProperty(encodings: encodings))
}
