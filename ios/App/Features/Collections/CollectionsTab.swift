import FilmcaseKit
import SwiftUI

private enum CollectionsRoute: Hashable {
    case collection(Int)
    case recipe(Int)
}

struct CollectionsTab: View {
    let environment: AppEnvironment

    var body: some View {
        NavigationStack {
            CollectionListView(model: environment.collections, thumbnails: environment.thumbnails)
                .navigationTitle("Collections")
                .navigationDestination(for: CollectionsRoute.self) { route in
                    switch route {
                    case .collection(let id):
                        CollectionDetailView(collectionID: id, environment: environment)
                    case .recipe(let id):
                        RecipeDetailView(recipeID: id, environment: environment)
                    }
                }
        }
    }
}

private struct CollectionListView: View {
    let model: CollectionsModel
    let thumbnails: ThumbnailLoader

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Loading collections")
            case .empty:
                ContentUnavailableView(
                    "No Collections", systemImage: "rectangle.stack",
                    description: Text("Create collections on your Filmcase server to push them to the camera."))
            case .error, .offline:
                FailureView(state: model.state) { Task { await model.load() } }
            case .loaded:
                List(model.collections) { collection in
                    NavigationLink(value: CollectionsRoute.collection(collection.id)) {
                        CollectionRow(collection: collection, thumbnails: thumbnails)
                    }
                }
                .refreshable { await model.load() }
            }
        }
        .task { await model.load() }
    }
}

private struct CollectionRow: View {
    let collection: CollectionSummary
    let thumbnails: ThumbnailLoader

    @ScaledMetric(relativeTo: .body) private var thumbnailSize = 48.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Column at accessibility sizes so names and film simulations are never cut off.
        AdaptiveStack(spacing: 12) {
            ThumbnailView(path: collection.coverThumbnailURLs.first ?? nil, loader: thumbnails)
                .frame(width: min(thumbnailSize, 96), height: min(thumbnailSize, 96))
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).font(.headline)
                Text(collection.filmSimulations.joined(separator: ", "))
                    .font(.subheadline).secondaryText()
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(collection.recipeCount, format: .number).secondaryText()
        }
        .accessibilityElement(children: .combine)
        // Inflected so one recipe reads "1 recipe". A model-owned label is requested in the
        // audit's open questions (CollectionSummary.accessibilityLabel).
        .accessibilityLabel(Text("\(collection.name), ^[\(collection.recipeCount) recipe](inflect: true)"))
    }
}

private struct CollectionDetailView: View {
    let collectionID: Int
    let environment: AppEnvironment

    @State private var showsPush = false

    private var model: CollectionsModel { environment.collections }

    var body: some View {
        Group {
            // Per-id state: a collection opened a moment ago never shows here.
            switch model.detailState(for: collectionID) {
            case .loading:
                ProgressView("Loading collection")
            case .empty:
                ContentUnavailableView(
                    "Empty Collection", systemImage: "rectangle.stack",
                    description: Text("This collection has no recipes."))
            case .error, .offline:
                FailureView(state: model.detailState(for: collectionID)) {
                    Task { await model.loadDetail(id: collectionID) }
                }
            case .loaded:
                recipeList
            }
        }
        .navigationTitle(model.detail(for: collectionID)?.name ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Push to camera", systemImage: "paperplane") { showsPush = true }
                    .disabled(model.orderedRecipes(for: collectionID).isEmpty)
            }
        }
        .task { await model.loadDetail(id: collectionID) }
        .sheet(isPresented: $showsPush) {
            // Written by the P7 worker (Features/Camera).
            // The push screen has a title, a toolbar and a Close button, so it needs its own stack.
            NavigationStack {
                CollectionPushView(collectionID: collectionID, environment: environment)
            }
        }
    }

    private var recipeList: some View {
        List {
            ForEach(Array(model.orderedRecipes(for: collectionID).enumerated()), id: \.element.id) { pair in
                NavigationLink(value: CollectionsRoute.recipe(pair.element.id)) {
                    HStack {
                        Text("\(pair.offset + 1)")
                            .appMonoFont(15, relativeTo: .body, bold: true)
                            .secondaryText()
                            .frame(minWidth: 28, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.element.name).font(.headline)
                            Text(pair.element.filmSimulation).font(.subheadline).secondaryText()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(pair.offset + 1), \(pair.element.name), \(pair.element.filmSimulation)")
                }
            }
        }
        .refreshable { await model.loadDetail(id: collectionID) }
    }
}
