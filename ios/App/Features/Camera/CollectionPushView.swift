// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import SwiftUI

struct CollectionPushView: View {
    private let collectionID: Int
    private let environment: any CameraFeatureEnvironment

    @State private var model: CollectionPushModel?
    @State private var loadError: String?

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
        .task { await load() }
    }

    private func load() async {
        do {
            let collection = try await environment.client.collection(id: collectionID)
            let workflow = try await environment.makeSlotWorkflow()
            model = try await CollectionPushModel.load(
                collection: collection, client: environment.client, workflow: workflow,
                clock: environment.clock)
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
                Section { Text(message).foregroundStyle(.red) }
            }
            bannerSection
            slotsSection
            unassignedSection
            validationSection
            actionsSection
        }
        .environment(\.editMode, .constant(model.phase == .editing ? .active : .inactive))
        .animation(reduceMotion ? nil : .default, value: model.assignment)
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
                Label(message ?? "The push stopped.", systemImage: "cable.connector.slash")
                    .foregroundStyle(.orange)
                Button("Resume") { Task { await model.resume() } }
                    .buttonStyle(.glassProminent)
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
                        Button("Clear", role: .destructive) { model.clear(slot: row.slot) }
                    }
                    .accessibilityAction(named: "Clear slot") { model.clear(slot: row.slot) }
            }
            .onMove { source, destination in
                // The model swaps; rows are slot-ordered, so translate the list move to slots.
                for from in source { model.move(from: from + 1, to: destination > from ? destination : destination + 1) }
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
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
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
                    .buttonStyle(.glassProminent)
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
        HStack {
            Text(row.title)
                .font(.headline.monospaced())
                .frame(minWidth: 36, alignment: .leading)
            Text(row.item?.name ?? "Empty")
                .foregroundStyle(row.item == nil ? .secondary : .primary)
            Spacer()
            statusView
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .none, .waiting?:
            EmptyView()
        case .pushing?:
            ProgressView().accessibilityLabel("Pushing")
        case .done(let result)?:
            switch result {
            case .verified:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Verified")
            case .partiallyFailed(let names):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Did not take: \(names.joined(separator: ", "))")
            case .connectionLost:
                Image(systemName: "cable.connector.slash").foregroundStyle(.red)
                    .accessibilityLabel("Connection lost")
            }
        }
    }
}
