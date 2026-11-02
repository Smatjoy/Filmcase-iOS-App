import SwiftUI

// Shared accessibility building blocks (docs/ios_accessibility_audit.md). No wording lives
// here: callers pass the text, which comes from FilmcaseKit models or is static UI copy.

/// Speaks `text` over whatever VoiceOver is reading. For async results that arrive while
/// focus is on something else (push verified/failed, camera connected/lost).
@MainActor
func announce(_ text: String) {
    guard !text.isEmpty else { return }
    // API: AccessibilityNotification.Announcement (iOS 17). VoiceOver-only; silent otherwise.
    AccessibilityNotification.Announcement(text).post()
}

/// A status line whose meaning never depends on colour: a shaped icon plus text. The tint
/// colours the icon only; the text stays `.primary` because system orange/green/red text
/// fails WCAG contrast on light backgrounds.
struct StatusLabel: View {
    let text: String
    let systemImage: String
    let tint: Color
    var font: Font = .body

    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(font)
    }
}

/// Lays children out in a row, flipping to a column at accessibility text sizes so nothing
/// truncates.
struct AdaptiveStack<Content: View>: View {
    private let horizontalAlignment: HorizontalAlignment
    private let verticalAlignment: VerticalAlignment
    private let spacing: CGFloat?
    private let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        horizontalAlignment: HorizontalAlignment = .leading,
        verticalAlignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content }
    }
}

/// Secondary text that becomes primary under Increase Contrast, so it stays legible on
/// tinted and translucent fills.
private struct SecondaryTextModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(
            contrast == .increased
                ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                : AnyShapeStyle(HierarchicalShapeStyle.secondary))
    }
}

extension View {
    func secondaryText() -> some View { modifier(SecondaryTextModifier()) }
}
