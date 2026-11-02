// The Lock Screen and Dynamic Island views for a push to the camera. They draw only the
// fields of `PushActivityContent`; every sentence and number comes from FilmcaseKit.

import ActivityKit  // API: ActivityViewContext
import FilmcaseKit
import SwiftUI
import WidgetKit  // API: ActivityConfiguration, DynamicIsland, DynamicIslandExpandedRegion

struct PushLiveActivity: Widget {
    var body: some WidgetConfiguration {
        // API: ActivityConfiguration(for:content:dynamicIsland:)
        ActivityConfiguration(for: PushActivityAttributes.self) { context in
            PushLockScreenView(content: context.state)
        } dynamicIsland: { context in
            let content = context.state
            // API: DynamicIsland { expanded regions } compactLeading: compactTrailing: minimal:
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: content.phase)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(content.title).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(content.completed)/\(content.total)")
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(content.statusLine).font(.subheadline).lineLimit(2)
                        ProgressView(value: content.fractionCompleted)
                            .tint(content.phase.tint)
                        SlotStrip(marks: content.slots)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(content.accessibilityLabel)
                }
            } compactLeading: {
                PhaseIcon(phase: content.phase)
            } compactTrailing: {
                Text("\(content.completed)/\(content.total)")
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel(content.accessibilityLabel)
            } minimal: {
                PhaseIcon(phase: content.phase)
                    .accessibilityLabel(content.accessibilityLabel)
            }
            .keylineTint(content.phase.tint)
        }
    }
}

private struct PushLockScreenView: View {
    let content: PushActivityContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PhaseIcon(phase: content.phase)
                Text(content.title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(content.completed)/\(content.total)")
                    .font(.headline.monospacedDigit())
            }
            Text(content.statusLine).font(.subheadline).lineLimit(2)
            ProgressView(value: content.fractionCompleted)
                .tint(content.phase.tint)
            SlotStrip(marks: content.slots)
        }
        .padding(16)
        // One element, one sentence from FilmcaseKit, instead of reading each mark.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
    }
}

/// C1...C7, each with a status icon. Decorative: the container carries the accessibility label.
private struct SlotStrip: View {
    let marks: [PushActivityContent.SlotMark]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(marks, id: \.slot) { mark in
                VStack(spacing: 2) {
                    Image(systemName: mark.status.symbolName)
                        .foregroundStyle(mark.status.tint)
                    Text("C\(mark.slot)").font(.caption2.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PhaseIcon: View {
    let phase: PushActivityContent.Phase

    var body: some View {
        Image(systemName: phase.symbolName)
            .foregroundStyle(phase.tint)
    }
}

extension PushActivityContent.Phase {
    fileprivate var symbolName: String {
        switch self {
        case .backingUp, .writing, .verifying: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .lost: "cable.connector.slash"
        case .failed: "xmark.circle.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .backingUp, .writing, .verifying: .blue
        case .done: .green
        case .partial: .orange
        case .lost, .failed: .red
        }
    }
}

extension PushActivityContent.SlotMark.Status {
    fileprivate var symbolName: String {
        switch self {
        case .waiting: "circle"
        case .active: "arrow.triangle.2.circlepath"
        case .verified: "checkmark.circle.fill"
        case .partial: "exclamationmark.triangle.fill"
        case .lost: "xmark.circle.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .waiting: .secondary
        case .active: .blue
        case .verified: .green
        case .partial: .orange
        case .lost: .red
        }
    }
}
