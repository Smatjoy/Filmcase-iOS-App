// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import SwiftUI

/// The C1-C7 grid. Cells render `SlotItem`; an optional tap forwards the slot index.
struct SlotGrid: View {
    let slots: [SlotItem]
    var onSelect: ((Int) -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(slots) { slot in
                if let onSelect {
                    Button { onSelect(slot.index) } label: { SlotCell(slot: slot) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(slot.accessibilityLabel)
                        .accessibilityAddTraits(.isButton)
                } else {
                    SlotCell(slot: slot)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(slot.accessibilityLabel)
                }
            }
        }
    }
}

struct SlotCell: View {
    let slot: SlotItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(slot.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(slot.displayName)
                .font(.headline)
                .lineLimit(2)
            Text(slot.filmSimName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
    }
}

/// Connection status. Read-only content, so a quiet fill rather than glass: glass is for
/// controls and navigation (swiftui-liquid-glass).
struct ConnectionPillView: View {
    let pill: ConnectionPill

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pill.isReady ? "cable.connector" : "cable.connector.slash")
                .foregroundStyle(pill.isReady ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(pill.text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.fill.tertiary, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera connection")
        .accessibilityValue(pill.text)
    }
}

/// How to connect, shown whenever no camera is ready.
struct HowToConnectCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("How to connect", systemImage: "cable.connector")
                .font(.headline)
            Text("1. Connect the camera to this device with a USB-C cable.")
            Text("2. On the camera, set the USB mode to USB RAW CONV./BACKUP RESTORE.")
            Text("3. Switch the camera on and allow access when asked.")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
