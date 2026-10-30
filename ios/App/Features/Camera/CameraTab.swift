// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import SwiftUI

struct CameraTab: View {
    private let environment: any CameraFeatureEnvironment

    @State private var backups: BackupsModel?
    @State private var setupError: String?

    init(environment: some CameraFeatureEnvironment) {
        self.environment = environment
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The shared CameraModel is observed for the app's lifetime by RootView,
                // and connects by itself when a camera is plugged in.
                CameraContent(model: environment.cameraModel, backups: backups)
                if let setupError {
                    Text(setupError).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("Camera")
        .toolbar {
            // A toolbar control, so the system gives it glass.
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh slots", systemImage: "arrow.clockwise") {
                    Task { await environment.cameraModel.refreshSlots() }
                }
                .disabled(!environment.cameraModel.isReady)
            }
        }
        .refreshable { await environment.cameraModel.refreshSlots() }
        .task { await loadBackups() }
    }

    private func loadBackups() async {
        do {
            let model = BackupsModel(store: environment.backupStore, workflow: try await environment.makeSlotWorkflow())
            backups = model
            await model.load()
        } catch {
            setupError = UserMessages.text(for: error)
        }
    }
}

private struct CameraContent: View {
    let model: CameraModel
    let backups: BackupsModel?

    var body: some View {
        ConnectionPillView(pill: model.pill)

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
        case .idle, .unauthorized, .lost:
            ConnectPrompt(
                model: model, message: UserMessages.text(for: model.connectionState),
                showsButton: model.autoConnectSuspension != nil)
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

/// The connection's status. A camera that is plugged in connects by itself; the button
/// appears only after the person declined access or disconnected.
private struct ConnectPrompt: View {
    let model: CameraModel
    let message: String
    let showsButton: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(message).font(.headline).multilineTextAlignment(.center)
            if showsButton {
                Button("Connect") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct BackupsSection: View {
    let backups: BackupsModel

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
