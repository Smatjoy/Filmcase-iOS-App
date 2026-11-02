// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import SwiftUI

struct CollectionPushView: View {
    private let collectionID: Int
    private let environment: any CameraFeatureEnvironment

    @State private var model: CollectionPushModel?
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    init(collectionID: Int, environment: some CameraFeatureEnvironment) {
        self.collectionID = collectionID
        self.environment = environment
    }

    var body: some View {
        Group {
            if let model {
                CollectionPushContent(model: model)
            } else if let loadError {
                ContentUnavailableView(
                    "Cannot load collection", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else {
                ProgressView("Loading recipes").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Push to camera")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The way out of the sheet for Switch Control, Voice Control and keyboard users,
            // who cannot drag it away. Held back while a run is writing to the camera.
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .disabled(isWorking)
            }
        }
        .interactiveDismissDisabled(isWorking)
        .task { await load() }
    }

    private var isWorking: Bool {
        guard let phase = model?.phase else { return false }
        return phase == .running || phase == .restoring
    }

    private func load() async {
        do {
            let collection = try await environment.client.collection(id: collectionID)
            let workflow = try await environment.makeSlotWorkflow()
            model = try await CollectionPushModel.load(
                collection: collection, client: environment.client, workflow: workflow,
                clock: environment.clock, activity: environment.pushActivity)
        } catch {
            loadError = UserMessages.text(for: error)
        }
    }
}

private struct CollectionPushContent: View {
    let model: CollectionPushModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            if let message = model.errorMessage {
                Section {
                    StatusLabel(text: message, systemImage: "xmark.octagon.fill", tint: .red)
                }
            }
            bannerSection
            slotsSection
            unassignedSection
            validationSection
            actionsSection
        }
        .environment(\.editMode, .constant(model.phase == .editing ? .active : .inactive))
        .animation(reduceMotion ? nil : .default, value: model.assignment)
        // The run goes on while VoiceOver focus sits elsewhere; say it when it stops or fails.
        .onChange(of: model.phase) { _, _ in
            if let text = model.completionAnnouncement { announce(text) }
        }
        .onChange(of: model.errorMessage) { _, message in announce(message ?? "") }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Auto-fill") { model.autoFill() }
                    .disabled(model.phase != .editing)
                Button("Clear all") { model.clearAll() }
                    .disabled(model.phase != .editing)
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var bannerSection: some View {
        switch model.phase {
        case .interrupted(_, let message):
            Section {
                StatusLabel(
                    text: message ?? "The push stopped.", systemImage: "cable.connector.slash",
                    tint: .orange)
                Button("Resume") { Task { await model.resume() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .editing, .running, .finished, .restoring, .restored:
            EmptyView()
        }
    }

    private var slotsSection: some View {
        Section {
            ForEach(model.rows) { row in
                SlotRowView(row: row, status: model.statuses[row.slot])
                    .swipeActions {
                        if model.phase == .editing {
                            Button("Clear", role: .destructive) { model.clear(slot: row.slot) }
                        }
                    }
                    // Swipe is invisible to Switch Control and Voice Control: same action here.
                    .accessibilityActions {
                        if model.phase == .editing {
                            Button("Clear slot") { model.clear(slot: row.slot) }
                        }
                    }
            }
            .onMove { source, destination in
                model.moveRows(fromOffsets: source, toOffset: destination)
            }
        } header: {
            Text("Slots")
        } footer: {
            if model.total > 0 {
                ProgressView(value: Double(model.completed), total: Double(model.total))
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(model.completed) of \(model.total) slots")
            }
        }
    }

    @ViewBuilder
    private var unassignedSection: some View {
        if !model.unassignedItems.isEmpty {
            Section("Not assigned") {
                ForEach(model.unassignedItems) { item in
                    Menu(item.name) {
                        ForEach(model.rows) { row in
                            Button("Put in \(row.title)") { model.assign(item.id, to: row.slot) }
                        }
                    }
                    .disabled(model.phase != .editing)
                }
            }
        }
    }

    @ViewBuilder
    private var validationSection: some View {
        if model.phase == .editing, !model.validationMessages.isEmpty {
            Section("Fix before pushing") {
                ForEach(model.validationMessages, id: \.self) { message in
                    StatusLabel(text: message, systemImage: "exclamationmark.circle.fill", tint: .orange)
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            switch model.phase {
            case .editing:
                Button("Push to camera") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canStart)
            case .running, .restoring:
                ProgressView(model.phase == .restoring ? "Restoring" : "Pushing")
            case .finished, .interrupted, .restored:
                Button("Arrange again") { model.editAgain() }
            }
            if model.canRestoreAll {
                Button("Restore all", role: .destructive) { Task { await model.restoreAll() } }
            }
        }
    }
}

private struct SlotRowView: View {
    let row: CollectionPushModel.SlotRow
    let status: CollectionPushModel.SlotStatus?

    var body: some View {
        // Column at accessibility sizes so the slot name and status never truncate.
        AdaptiveStack(spacing: 8) {
            Text(row.title)
                .font(.headline.monospaced())
                .frame(minWidth: 36, alignment: .leading)
            Text(row.displayName)
                .foregroundStyle(row.item == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                if let text = status?.displayText {
                    Text(text).font(.caption).secondaryText()
                }
                // Which settings did not take, visible (not only for VoiceOver).
                if let detail = status?.detailText {
                    Text(detail).font(.caption2).secondaryText()
                }
            }
            // Status is never colour alone: each indicator has its own shape and the row
            // also carries the status as text.
            StatusIcon(indicator: status?.indicator ?? .none)
        }
        // One stop: "C3, Kodak Portra 400" with the status as its value. The visible text and
        // the icon are folded in here instead of being read as duplicates.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(row.displayName)")
        .accessibilityValue(status?.accessibilityText ?? "")
    }
}

/// Icon and colour for a status; the wording comes from the model.
private struct StatusIcon: View {
    let indicator: CollectionPushModel.StatusIndicator

    var body: some View {
        switch indicator {
        case .none:
            EmptyView()
        case .progress:
            ProgressView()
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failure:
            Image(systemName: "cable.connector.slash").foregroundStyle(.red)
        }
    }
}
