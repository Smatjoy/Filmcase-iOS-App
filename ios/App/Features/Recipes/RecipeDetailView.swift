import FilmcaseKit
import SwiftUI

struct RecipeDetailView: View {
    let environment: AppEnvironment

    @State private var model: RecipeDetailModel
    @State private var showsSendSheet = false
    @State private var showsRename = false
    @State private var draftName = ""
    @State private var showsEditor = false
    @State private var showsRemoveConfirmation = false

    @Environment(\.dismiss) private var dismiss

    init(recipeID: Int, environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: environment.makeRecipeDetailModel(id: recipeID))
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading recipe")
            case .error, .offline:
                FailureView(state: model.state) { Task { await model.load() } }
            case .loaded, .empty:
                content
            }
        }
        .navigationTitle(model.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.detail != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Recipe actions", systemImage: "ellipsis") {
                        Button("Edit", systemImage: "slider.horizontal.3") { showsEditor = true }
                        Button("Rename", systemImage: "pencil", action: beginRename)
                            .disabled(model.isRenaming)
                        Divider()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            showsRemoveConfirmation = true
                        }
                    }
                }
            }
        }
        .alert(model.renamePromptTitle, isPresented: $showsRename) {
            TextField("Name", text: $draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            Button("Save") { Task { await model.rename(to: draftName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The camera shows this name on the slot. Up to 25 characters, without accents.")
        }
        .alert("Could not rename", isPresented: renameFailed) {
            Button("Try again", action: beginRename)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.renameError ?? "")
        }
        .confirmationDialog(
            "Remove \(model.titleText)?", isPresented: $showsRemoveConfirmation, titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await model.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves your library for good. Slots on the camera are not affected.")
        }
        .alert("Could not remove", isPresented: removeFailed) {
            Button("OK", role: .cancel) { model.clearRemoveError() }
        } message: {
            Text(model.removeError ?? "")
        }
        .sheet(isPresented: $showsEditor) {
            RecipeEditorView(mode: .edit(id: model.recipeID), environment: environment) { _ in
                Task {
                    await model.load()
                    await environment.library.reload()
                }
            }
        }
        // The list shows the name too.
        .onChange(of: model.renameCount) { _, _ in
            Task { await environment.library.reload() }
        }
        .onChange(of: model.wasRemoved) { _, removed in
            guard removed else { return }
            Task { await environment.library.reload() }
            dismiss()
        }
        .task { await model.load() }
        // A camera connected or left: judge the recipe against it again.
        .onChange(of: environment.cameraModel.isReady) { _, _ in
            Task { await model.recheckCamera() }
        }
        .sheet(isPresented: $showsSendSheet) {
            // Written by the P7 worker (Features/Camera).
            if let recipe = model.cameraRecipe {
                SendToCameraSheet(recipe: recipe, environment: environment)
            }
        }
    }

    private var removeFailed: Binding<Bool> {
        Binding(get: { model.removeError != nil }, set: { if !$0 { model.clearRemoveError() } })
    }

    private var renameFailed: Binding<Bool> {
        Binding(get: { model.renameError != nil }, set: { if !$0 { model.clearRenameError() } })
    }

    private func beginRename() {
        model.clearRenameError()
        draftName = model.detail?.name ?? ""
        showsRename = true
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let detail = model.detail {
                    ThumbnailView(path: detail.coverThumbnailURL, loader: environment.thumbnails)
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 16))
                    header(detail)
                }
                SpecSheetView(sections: model.specSections)
                sendSection
            }
            .padding()
        }
    }

    private func header(_ detail: RecipeDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FilmSimSwatch(name: detail.filmSimulation)
            if let text = model.descriptionText {
                Text(text).font(.body)
            }
        }
    }

    @ViewBuilder
    private var sendSection: some View {
        if model.needsName {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: beginRename) {
                    Label("Name this recipe", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if let reason = model.sendBlockedReason {
                    Text(reason).font(.footnote).secondaryText()
                }
            }
        } else {
            sendButton
        }
    }

    private var sendButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsSendSheet = true
            } label: {
                Label("Send to camera", systemImage: "paperplane")
                    .frame(maxWidth: .infinity)
            }
            // In-content primary action: standard prominent style, glass is for controls
            // and navigation (swiftui-liquid-glass).
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canSendToCamera)
            // A dimmed button says nothing about why; the model's reason becomes its hint.
            .accessibilityHint(model.sendBlockedReason ?? "")
            if let reason = model.sendBlockedReason {
                Text(reason).font(.footnote).secondaryText()
            }
        }
    }
}

/// The film simulation as a brand-styled chip (the web's per-simulation tiles are not bundled).
private struct FilmSimSwatch: View {
    let name: String

    var body: some View {
        Label {
            Text(name.uppercased()).appLabelFont(13, relativeTo: .footnote, weight: .semibold)
        } icon: {
            Image(systemName: "camera.filters")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.tint.opacity(0.15), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Film simulation, \(name)")
    }
}

/// Dense monospaced spec sheet: Archivo labels, Space Mono values, stacked at accessibility sizes.
private struct SpecSheetView: View {
    let sections: [SpecSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title.uppercased())
                        .appLabelFont(12, relativeTo: .caption, weight: .bold)
                        .secondaryText()
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows) { row in
                        SpecRowView(row: row)
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("specSheet")
    }
}

private struct SpecRowView: View {
    let row: SpecRow

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Stack label over value at accessibility sizes so the mono values never truncate.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(row.label).appLabelFont(15, relativeTo: .subheadline)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
            Text(row.value)
                .appMonoFont(15, relativeTo: .subheadline)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        // One swipe stop per row: "Highlight, +2" rather than two.
        .accessibilityElement(children: .combine)
    }
}
