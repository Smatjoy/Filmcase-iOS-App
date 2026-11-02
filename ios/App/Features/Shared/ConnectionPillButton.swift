import FilmcaseKit
import SwiftUI

/// The persistent camera connection pill. Tapping it opens the Camera tab.
struct ConnectionPillButton: View {
    let model: CameraModel
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pill = model.pill
        Button(action: open) {
            HStack(spacing: 8) {
                // Different shape per state, so the green is not the only signal.
                Image(systemName: pill.isReady ? "cable.connector" : "cable.connector.slash")
                    .foregroundStyle(pill.isReady ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(pill.text)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Reduce Motion: state changes are instant instead of cross-fading.
        .animation(reduceMotion ? nil : .default, value: pill)
        .accessibilityLabel("Camera connection")
        .accessibilityValue(pill.text)
        .accessibilityHint("Opens the Camera tab")
    }
}
