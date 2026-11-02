// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// The web brand: Archivo for labels, Space Mono for values (both OFL, registered through
// UIAppFonts). `relativeTo:` keeps them scaling with Dynamic Type (axiom-design typography).
// If a font fails to register, SwiftUI silently falls back to the system font.

import SwiftUI

enum AppFont {
    /// Archivo is a variable font; the family name selects it and `.weight` picks the instance.
    static func label(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .custom("Archivo", size: size, relativeTo: style).weight(weight)
    }

    static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle, bold: Bool = false) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size, relativeTo: style)
    }
}

// Custom fonts do not follow Bold Text on their own (system fonts do). These modifiers read
// `legibilityWeight` and step the weight up, so the brand fonts honour the setting too.
private struct AppLabelFontModifier: ViewModifier {
    let size: CGFloat
    let style: Font.TextStyle
    let weight: Font.Weight

    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content.font(AppFont.label(size, relativeTo: style, weight: legibilityWeight == .bold ? boosted : weight))
    }

    private var boosted: Font.Weight {
        if weight == .regular { return .semibold }
        if weight == .semibold { return .bold }
        return .heavy
    }
}

private struct AppMonoFontModifier: ViewModifier {
    let size: CGFloat
    let style: Font.TextStyle
    let bold: Bool

    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content.font(AppFont.mono(size, relativeTo: style, bold: bold || legibilityWeight == .bold))
    }
}

extension View {
    func appLabelFont(_ size: CGFloat, relativeTo style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(AppLabelFontModifier(size: size, style: style, weight: weight))
    }

    func appMonoFont(_ size: CGFloat, relativeTo style: Font.TextStyle, bold: Bool = false) -> some View {
        modifier(AppMonoFontModifier(size: size, style: style, bold: bold))
    }
}
