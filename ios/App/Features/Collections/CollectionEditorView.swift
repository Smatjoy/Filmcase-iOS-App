// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// A collection's name and recipes. The order here is the order they fill C1 upwards.

import FilmcaseKit
import SwiftUI

struct CollectionEditorView: View {
    @State private var model: CollectionEditorModel
    /// Called with the collection's id once a save went through.
    let onSaved: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    init(mode: CollectionEditorModel.Mode, environment: AppEnvironment, onSaved: @escaping (Int) -> Void) {
        _model = State(initialValue: CollectionEditorModel(mode: mode, client: environment.client))
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
                    CollectionEditorForm(model: model)
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
        .onChange(of: model.savedCollectionID) { _, id in
            guard let id else { return }
            onSaved(id)
            dismiss()
        }
    }

    private var failed: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.clearError() } })
    }
}

private struct CollectionEditorForm: View {
    @Bindable var model: CollectionEditorModel

    var body: some View {
        List {
            Section("Name") {
                TextField("Name", text: $model.name)
                    .textInputAutocapitalization(.words)
            }
            Section {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                    HStack(spacing: 12) {
                        Text("C\(offset + 1)")
                            .appMonoFont(15, relativeTo: .subheadline, bold: true)
                            .secondaryText()
                            .frame(minWidth: 30, alignment: .leading)
                        recipeLabel(item)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("collectionItem")
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { model.remove(atOffsets: $0) }
            } header: {
                Text("Recipes")
            } footer: {
                if model.items.isEmpty {
                    Text("Add recipes below. Their order here is the order they fill the slots.")
                } else if let notice = model.itemsNotice {
                    Text(notice)
                } else {
                    Text("Touch and hold a recipe, then drag to reorder. Swipe left to take it out.")
                }
            }
            Section("Add recipes") {
                TextField("Search recipes", text: $model.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ForEach(model.candidates) { item in
                    Button { model.add(item) } label: {
                        HStack {
                            recipeLabel(item)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .tint(.primary)
                    .accessibilityHint("Adds this recipe to the collection")
                }
            }
        }
        .task(id: model.searchText) {
            // Waits for a pause in typing; a new keystroke cancels this.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }

    private func recipeLabel(_ item: CollectionEditorItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName).font(.body)
            Text(item.filmSimulation).font(.footnote).secondaryText()
        }
    }
}
