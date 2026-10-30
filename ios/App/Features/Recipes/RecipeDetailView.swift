import FilmcaseKit
import SwiftUI

struct RecipeDetailView: View {
    let environment: AppEnvironment

    @State private var model: RecipeDetailModel
    @State private var showsSendSheet = false

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
        .navigationTitle(model.detail?.name ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
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

    private var sendSection: some View {
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
            if let reason = model.sendBlockedReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// The film simulation as a brand-styled chip (the web's per-simulation tiles are not bundled).
private struct FilmSimSwatch: View {
    let name: String

    var body: some View {
        Label {
            Text(name.uppercased()).font(AppFont.label(13, relativeTo: .footnote, weight: .semibold))
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
                        .font(AppFont.label(12, relativeTo: .caption, weight: .bold))
                        .foregroundStyle(.secondary)
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
            Text(row.label).font(AppFont.label(15, relativeTo: .subheadline))
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
            Text(row.value)
                .font(AppFont.mono(15, relativeTo: .subheadline))
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
    }
}
