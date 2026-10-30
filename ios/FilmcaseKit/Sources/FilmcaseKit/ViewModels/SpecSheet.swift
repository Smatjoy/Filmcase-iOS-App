// The recipe detail's spec sheet: ordered sections of (label, value) rows. Labels, section
// grouping and the signed number format follow the web template
// (src/interfaces/templates/recipes/partials/recipe_detail.html).

import Foundation

public struct SpecRow: Equatable, Identifiable, Sendable {
    public let label: String
    public let value: String
    public var id: String { label }
}

public struct SpecSection: Equatable, Identifiable, Sendable {
    public let title: String
    public let rows: [SpecRow]
    public var id: String { title }
}

public enum SpecSheet {
    /// The sections that apply to *detail*; a section with no rows is left out.
    public static func sections(for detail: RecipeDetail) -> [SpecSection] {
        var sections: [SpecSection] = []

        func add(_ title: String, _ rows: [SpecRow?]) {
            let rows = rows.compactMap { $0 }
            if !rows.isEmpty { sections.append(SpecSection(title: title, rows: rows)) }
        }

        add("Basic", [
            row("Name", detail.name),
            row("Film Simulation", detail.filmSimulation),
        ])
        add("Dynamic Range", [
            row("Dynamic Range", detail.dynamicRange),
            row("D-Range Priority", detail.dRangePriority),
        ])
        let grainIsOn = !isOff(detail.grainRoughness)
        add("Grain", [
            row("Grain Roughness", detail.grainRoughness),
            grainIsOn ? row("Grain Size", detail.grainSize) : nil,
        ])
        add("White Balance", [
            row("White Balance", detail.whiteBalance),
            SpecRow(label: "Red", value: signed(detail.whiteBalanceRed)),
            SpecRow(label: "Blue", value: signed(detail.whiteBalanceBlue)),
        ])
        add("Color Chrome", [
            row("Color Chrome Effect", detail.colorChromeEffect),
            row("Color Chrome FX Blue", detail.colorChromeFXBlue),
        ])
        add("Tone & Color", [
            number("Highlight", detail.highlight),
            number("Shadow", detail.shadow),
            number("Color", detail.color),
        ])
        add("Detail", [
            number("Sharpness", detail.sharpness),
            number("High ISO NR", detail.highISONR),
            number("Clarity", detail.clarity),
        ])
        if detail.isMonochromatic {
            add("BW Tone", [
                number("BW Warm / Cool", detail.monochromaticColorWarmCool),
                number("BW Magenta / Green", detail.monochromaticColorMagentaGreen),
            ])
        }
        add("Camera", [
            list("Sensors", detail.sensors),
            list("Bodies", detail.bodies),
        ])
        return sections
    }

    /// An explicit sign for anything above zero: `+2`, `0`, `-1.5`, `+0.5`.
    public static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    public static func signed(_ value: Double) -> String {
        if value == value.rounded() { return signed(Int(value)) }
        return value > 0 ? "+\(value)" : "\(value)"
    }

    private static func isOff(_ value: String) -> Bool {
        value.isEmpty || value == "Off"
    }

    private static func row(_ label: String, _ value: String) -> SpecRow? {
        value.isEmpty ? nil : SpecRow(label: label, value: value)
    }

    private static func number(_ label: String, _ value: Double?) -> SpecRow? {
        value.map { SpecRow(label: label, value: signed($0)) }
    }

    private static func list(_ label: String, _ values: [String]) -> SpecRow? {
        values.isEmpty ? nil : SpecRow(label: label, value: values.joined(separator: ", "))
    }
}
