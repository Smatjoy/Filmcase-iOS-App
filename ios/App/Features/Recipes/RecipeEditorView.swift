// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// The recipe form. Choices, ranges and every rule come from RecipeEditorModel.

import FilmcaseKit
import SwiftUI

struct RecipeEditorView: View {
    @State private var model: RecipeEditorModel
    /// Called with the recipe's id once a save went through.
    let onSaved: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    init(mode: RecipeEditorModel.Mode, environment: AppEnvironment, onSaved: @escaping (Int) -> Void) {
        _model = State(initialValue: environment.makeRecipeEditorModel(mode: mode))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    ProgressView("Loading")
                case .error, .offline:
                    FailureView(state: model.state) { Task { await model.load() } }
                case .loaded, .empty:
                    RecipeEditorForm(model: model)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.canSave)
                }
            }
            .alert("Could not save", isPresented: failed) {
                Button("OK", role: .cancel) { model.clearError() }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(model.isSaving)
        .task { await model.load() }
        .onChange(of: model.savedRecipeID) { _, id in
            guard let id else { return }
            onSaved(id)
            dismiss()
        }
    }

    private var failed: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })
    }
}

private struct RecipeEditorForm: View {
    @Bindable var model: RecipeEditorModel

    var body: some View {
        Form {
            if let notice = model.lockedNotice {
                Section {
                    Text(notice).font(.subheadline)
                    if model.canSaveAsVersion {
                        Button("Save as new version") { Task { await model.saveAsNewVersion() } }
                            .disabled(!model.canSaveNewVersion)
                    }
                }
            }
            Section {
                TextField("Name", text: $model.draft.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                TextField("Description", text: $model.draft.description, axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                if let reason = model.saveBlockedReason {
                    Text(reason)
                } else {
                    Text("The camera shows the name on the slot. Up to 25 characters, without accents.")
                }
            }
            Group {
                filmSection
                toneSection
                whiteBalanceSection
                grainSection
                detailSection
            }
            // With images the settings stay; a new version can still differ, so they stay
            // editable when a version can be saved.
            .disabled(!model.settingsEditable && !model.canSaveAsVersion)
        }
    }

    private var filmSection: some View {
        Section("Film simulation") {
            choicePicker("Film simulation", field: "film_simulation", selection: $model.draft.filmSimulation)
            if model.showsMonochromeToning {
                numberRow(
                    "Warm / Cool", field: "monochromatic_color_warm_cool",
                    value: decimal(\.monochromaticColorWarmCool), fallback: .init(min: -9, max: 9, step: 1))
                numberRow(
                    "Magenta / Green", field: "monochromatic_color_magenta_green",
                    value: decimal(\.monochromaticColorMagentaGreen), fallback: .init(min: -9, max: 9, step: 1))
            }
        }
    }

    private var toneSection: some View {
        Section("Dynamic range and tone") {
            choicePicker("D-Range Priority", field: "d_range_priority", selection: $model.draft.dRangePriority)
            if model.showsDynamicRange {
                Picker("Dynamic range", selection: optionalChoice(\.dynamicRange)) {
                    ForEach(model.choices("dynamic_range").filter { !$0.isEmpty }, id: \.self) { Text($0).tag($0) }
                }
            }
            numberRow("Highlight", field: "highlight", value: decimal(\.highlight), fallback: .init(min: -2, max: 4, step: 0.5))
            numberRow("Shadow", field: "shadow", value: decimal(\.shadow), fallback: .init(min: -2, max: 4, step: 0.5))
            if !model.showsMonochromeToning {
                numberRow("Color", field: "color", value: optionalInt(\.color), fallback: .init(min: -4, max: 4, step: 1))
            }
        }
    }

    private var whiteBalanceSection: some View {
        Section("White balance") {
            choicePicker("White balance", field: "white_balance", selection: $model.draft.whiteBalance)
            if model.showsKelvin {
                LabeledContent("Temperature (K)") {
                    TextField("6500", value: $model.draft.kelvinTemperature, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            numberRow("Red shift", field: "white_balance_red", value: int(\.whiteBalanceRed), fallback: .init(min: -9, max: 9, step: 1))
            numberRow("Blue shift", field: "white_balance_blue", value: int(\.whiteBalanceBlue), fallback: .init(min: -9, max: 9, step: 1))
        }
    }

    private var grainSection: some View {
        Section("Grain and color chrome") {
            choicePicker("Grain", field: "grain_roughness", selection: $model.draft.grainRoughness)
            if model.showsGrainSize {
                Picker("Grain size", selection: grainSize) {
                    ForEach(model.grainSizes, id: \.self) { Text($0).tag($0) }
                }
            }
            choicePicker("Color Chrome", field: "color_chrome_effect", selection: $model.draft.colorChromeEffect)
            choicePicker("Color Chrome FX Blue", field: "color_chrome_fx_blue", selection: $model.draft.colorChromeFxBlue)
        }
    }

    private var detailSection: some View {
        Section("Detail") {
            numberRow("Sharpness", field: "sharpness", value: int(\.sharpness), fallback: .init(min: -4, max: 4, step: 1))
            numberRow("High ISO NR", field: "high_iso_nr", value: int(\.highIsoNr), fallback: .init(min: -4, max: 4, step: 1))
            numberRow("Clarity", field: "clarity", value: int(\.clarity), fallback: .init(min: -5, max: 5, step: 1))
        }
    }

    // --- rows ---

    private func choicePicker(_ title: String, field: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(model.choices(field), id: \.self) { Text($0).tag($0) }
        }
    }

    private func numberRow(
        _ title: String, field: String, value: Binding<Double>, fallback: RecipeFieldRange
    ) -> some View {
        let range = model.range(field, fallback: fallback)
        return Stepper(value: value, in: range.min...range.max, step: range.step) {
            LabeledContent(title, value: value.wrappedValue.formatted(.number.sign(strategy: .always(includingZero: false))))
        }
    }

    // --- bindings: the form works in Doubles; unset numbers show as 0 ---

    private func decimal(_ path: WritableKeyPath<RecipeDraft, Double?>) -> Binding<Double> {
        Binding(get: { model.draft[keyPath: path] ?? 0 }, set: { model.draft[keyPath: path] = $0 })
    }

    private func int(_ path: WritableKeyPath<RecipeDraft, Int>) -> Binding<Double> {
        Binding(get: { Double(model.draft[keyPath: path]) }, set: { model.draft[keyPath: path] = Int($0) })
    }

    private func optionalInt(_ path: WritableKeyPath<RecipeDraft, Int?>) -> Binding<Double> {
        Binding(get: { Double(model.draft[keyPath: path] ?? 0) }, set: { model.draft[keyPath: path] = Int($0) })
    }

    private func optionalChoice(_ path: WritableKeyPath<RecipeDraft, String?>) -> Binding<String> {
        Binding(
            get: { model.draft[keyPath: path] ?? model.choices("dynamic_range").first ?? "" },
            set: { model.draft[keyPath: path] = $0 })
    }

    /// Turning grain on starts at the first size, since "Off" is not one to pick.
    private var grainSize: Binding<String> {
        Binding(
            get: {
                let size = model.draft.grainSize ?? ""
                return model.grainSizes.contains(size) ? size : model.grainSizes.first ?? ""
            },
            set: { model.draft.grainSize = $0 })
    }
}
