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
