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

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(path: collection.coverThumbnailURLs.first ?? nil, loader: thumbnails)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).font(.headline)
                Text(collection.filmSimulations.joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(collection.recipeCount, format: .number).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection.name), \(collection.recipeCount) recipes")
    }
}

private struct CollectionDetailView: View {
    let collectionID: Int
    let environment: AppEnvironment

    @State private var showsPush = false

    private var model: CollectionsModel { environment.collections }

    var body: some View {
        Group {
            // The shared model may still hold the previously opened collection for a moment.
            if model.selectedID != collectionID {
                ProgressView()
            } else {
                switch model.detailState {
                case .loading:
                    ProgressView("Loading collection")
                case .empty:
                    ContentUnavailableView(
                        "Empty Collection", systemImage: "rectangle.stack",
                        description: Text("This collection has no recipes."))
                case .error, .offline:
                    FailureView(state: model.detailState) { Task { await model.loadDetail(id: collectionID) } }
                case .loaded:
                    recipeList
                }
            }
        }
        .navigationTitle(model.detail?.name ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Push to camera", systemImage: "paperplane") { showsPush = true }
                    .disabled(model.orderedRecipes.isEmpty)
            }
        }
        .task { await model.loadDetail(id: collectionID) }
        .sheet(isPresented: $showsPush) {
            // Written by the P7 worker (Features/Camera).
            CollectionPushView(collectionID: collectionID, environment: environment)
        }
    }

    private var recipeList: some View {
        List {
            ForEach(Array(model.orderedRecipes.enumerated()), id: \.element.id) { pair in
                NavigationLink(value: CollectionsRoute.recipe(pair.element.id)) {
                    HStack {
                        Text("\(pair.offset + 1)")
                            .font(AppFont.mono(15, relativeTo: .body, bold: true))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.element.name).font(.headline)
                            Text(pair.element.filmSimulation).font(.subheadline).foregroundStyle(.secondary)
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
