// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import SwiftUI

struct CameraTab: View {
    private let environment: any CameraFeatureEnvironment

    @State private var model: CameraModel?
    @State private var backups: CameraBackupsModel?
    @State private var setupError: String?

    init(environment: some CameraFeatureEnvironment) {
        self.environment = environment
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let model {
                    CameraContent(model: model, backups: backups)
                } else if let setupError {
                    ContentUnavailableView(
                        "Camera unavailable", systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Camera")
        .task { await run() }
    }

    /// Build the models, then follow the connection until the view goes away.
    private func run() async {
        do {
            let camera = try await environment.makeCameraModel()
            let workflow = try await environment.makeSlotWorkflow()
            model = camera
            backups = CameraBackupsModel(store: environment.backupStore, workflow: workflow)
            await backups?.load()
            await camera.observe()
        } catch {
            setupError = UserMessages.text(for: error)
        }
    }
}

private struct CameraContent: View {
    let model: CameraModel
    let backups: CameraBackupsModel?

    var body: some View {
        HStack {
            ConnectionPillView(pill: model.pill)
            Spacer()
            Button {
                Task { await model.refreshSlots() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.glass)
            .disabled(!model.isReady)
            .accessibilityLabel("Refresh slots")
        }

        stateSection

        if !model.isReady {
            HowToConnectCard()
        }

        if let backups {
            BackupsSection(backups: backups)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.connectionState {
        case .idle:
            ConnectPrompt(model: model, message: UserMessages.text(for: model.connectionState))
        case .unauthorized:
            ConnectPrompt(
                model: model, message: UserMessages.text(for: model.connectionState),
                title: "Try again")
        case .lost:
            ConnectPrompt(
                model: model, message: UserMessages.text(for: model.connectionState),
                title: "Reconnect")
        case .awaitingAuthorization, .searching, .opening:
            ProgressView(UserMessages.text(for: model.connectionState))
                .frame(maxWidth: .infinity)
        case .ready, .busy, .recovering:
            slotsSection
        }
    }

    @ViewBuilder
    private var slotsSection: some View {
        switch model.slotsState {
        case .idle, .loading:
            ProgressView("Reading slots").frame(maxWidth: .infinity)
        case .loaded:
            SlotGrid(slots: model.slots)
        case .failed(let message):
            ContentUnavailableView(
                "Could not read slots", systemImage: "exclamationmark.triangle",
                description: Text(message))
        }
    }
}

private struct ConnectPrompt: View {
    let model: CameraModel
    let message: String
    var title = "Connect"

    var body: some View {
        VStack(spacing: 12) {
            Text(message).font(.headline)
            Button(title) { Task { await model.connect() } }
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct BackupsSection: View {
    let backups: CameraBackupsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backups").font(.headline)
            Text("The latest backup of each slot, taken before it was overwritten.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(backups.backups) { backup in
                HStack {
                    VStack(alignment: .leading) {
                        Text("C\(backup.slotIndex), \(backup.slotName)").font(.body)
                        Text(backup.capturedAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { Task { await backups.restore(backup) } }
                        .buttonStyle(.bordered)
                        .disabled(backups.isRestoring)
                        .accessibilityLabel("Restore C\(backup.slotIndex), \(backup.slotName)")
                }
                .accessibilityElement(children: .contain)
            }
            if let message = backups.message {
                Text(message).font(.footnote).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .sensoryFeedback(.success, trigger: backups.successCount)
    }
}
