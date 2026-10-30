// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import SwiftUI

struct SendToCameraSheet: View {
    private let recipe: Recipe
    private let environment: any CameraFeatureEnvironment

    @State private var model: PushSheetModel?
    @State private var camera: CameraModel?
    @State private var setupError: String?
    @Environment(\.dismiss) private var dismiss

    init(recipe: Recipe, environment: some CameraFeatureEnvironment) {
        self.recipe = recipe
        self.environment = environment
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model, let camera {
                    PushSheetContent(model: model, camera: camera)
                } else if let setupError {
                    ContentUnavailableView(
                        "Cannot reach the camera", systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else {
                    ProgressView("Reading slots").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Send to camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let camera = try await environment.makeCameraModel()
            await camera.refreshSlots()
            let workflow = try await environment.makeSlotWorkflow()
            self.camera = camera
            model = PushSheetModel(recipe: recipe, slots: camera.slots, workflow: workflow)
            setupError = camera.errorMessage
        } catch {
            setupError = UserMessages.text(for: error)
        }
    }
}

private struct PushSheetContent: View {
    let model: PushSheetModel
    let camera: CameraModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.recipe.name).font(.title3.weight(.semibold))
                phaseContent
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sensoryFeedback(.success, trigger: model.successCount)
        .sensoryFeedback(.warning, trigger: model.problemCount)
        .confirmationDialog(
            "Overwrite slot?", isPresented: confirmationBinding, titleVisibility: .visible
        ) {
            Button("Back up and overwrite", role: .destructive) {
                // API: Task.immediate (Swift 6.2) runs up to the first suspension synchronously, so
                // the model leaves `.confirming` before the dialog's dismissal reports cancel.
                Task.immediate { await model.confirm() }
            }
            Button("Cancel", role: .cancel) { model.cancelConfirmation() }
        } message: {
            Text(model.overwriteWarning ?? "")
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { if case .confirming = model.phase { true } else { false } },
            set: { if !$0 { model.cancelConfirmation() } })
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .choosingSlot, .confirming:
            Text("Choose a slot. Its current recipe is backed up first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            SlotGrid(slots: model.slots) { model.choose(slot: $0) }
        case .pushing(let slot):
            WorkingView(text: "Backing up and writing C\(slot)")
        case .restoring(let slot):
            WorkingView(text: "Restoring C\(slot)")
        case .finished(let outcome):
            ResultView(model: model, camera: camera, outcome: outcome)
        }
    }
}

private struct WorkingView: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}

private struct ResultView: View {
    let model: PushSheetModel
    let camera: CameraModel
    let outcome: PushSheetModel.Outcome

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            resultBody
                .transition(.opacity)

            if model.canRestore {
                Button("Restore previous recipe") { Task { await model.restore() } }
                    .buttonStyle(.glass)
            }
            Button("Choose another slot") {
                Task {
                    model.chooseAnother()
                    await camera.refreshSlots()
                    model.updateSlots(camera.slots)
                }
            }
            .buttonStyle(.glassProminent)
        }
        .animation(reduceMotion ? nil : .default, value: outcome)
    }

    @ViewBuilder
    private var resultBody: some View {
        switch outcome.result {
        case .verified:
            Label("C\(outcome.slot) verified", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
        case .partiallyFailed:
            VStack(alignment: .leading, spacing: 8) {
                Label("Some properties did not take", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(outcome.diff) { row in
                    Text(row.label)
                        .accessibilityLabel("\(row.label) did not take")
                }
            }
        case .connectionLost:
            Label("The camera connection was lost", systemImage: "cable.connector.slash")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
        }
    }
}
