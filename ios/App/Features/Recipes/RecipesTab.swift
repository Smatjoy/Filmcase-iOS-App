import FilmcaseKit
import SwiftUI

struct RecipesTab: View {
    let environment: AppEnvironment

    var body: some View {
        NavigationStack {
            RecipeListView(library: environment.library, thumbnails: environment.thumbnails)
                .navigationTitle("Recipes")
                .navigationDestination(for: Int.self) { id in
                    RecipeDetailView(recipeID: id, environment: environment)
                }
        }
    }
}

private struct RecipeListView: View {
    @Bindable var library: LibraryModel
    let thumbnails: ThumbnailLoader

    @State private var showsFilters = false

    var body: some View {
        // One stable wrapper keeps the search field alive across loading/empty/error states.
        Group {
            switch library.state {
            case .loading where library.recipes.isEmpty:
                ProgressView("Loading recipes")
            case .empty:
                emptyView
            case .error, .offline:
                FailureView(state: library.state) { Task { await library.reload() } }
            case .loading, .loaded:
                list
            }
        }
        .searchable(text: $library.searchText, prompt: "Search recipes")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { favoritesButton }
            ToolbarItem(placement: .topBarTrailing) { filtersButton }
        }
        .sheet(isPresented: $showsFilters) { FacetFilterSheet(library: library) }
        .task { await library.loadIfNeeded() }
    }

    private var list: some View {
        List {
            ForEach(library.recipes) { recipe in
                NavigationLink(value: recipe.id) {
                    RecipeRow(recipe: recipe, thumbnails: thumbnails)
                }
                .onAppear { library.loadMoreIfNeeded(currentItem: recipe) }
            }
            footer
        }
        .listStyle(.plain)
        .overlay { if library.state == .loading { ProgressView() } }
        .refreshable { await library.refresh() }
    }

    @ViewBuilder
    private var footer: some View {
        if library.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
        } else if let message = library.loadMoreError {
            VStack(spacing: 8) {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { library.retryLoadMore() }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Recipes", systemImage: "camera.filters")
        } description: {
            Text(library.hasActiveFilters || !library.searchText.isEmpty
                 ? "Nothing matches the current search and filters."
                 : "This server has no recipes yet.")
        } actions: {
            if library.hasActiveFilters {
                Button("Clear Filters") { library.clearFilters() }
            }
        }
    }

    private var favoritesButton: some View {
        Button {
            library.favoritesOnly.toggle()
        } label: {
            Label("Favourites", systemImage: library.favoritesOnly ? "heart.fill" : "heart")
        }
        .accessibilityValue(library.favoritesOnly ? "On" : "Off")
        .accessibilityHint("Shows only favourite recipes")
    }

    private var filtersButton: some View {
        Button {
            showsFilters = true
        } label: {
            Label(
                "Filters",
                systemImage: library.selectedFacets.isEmpty
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityValue(library.selectedFacets.isEmpty ? "No filters" : "Filters applied")
    }
}

private struct RecipeRow: View {
    let recipe: RecipeSummary
    let thumbnails: ThumbnailLoader

    // Scales the thumbnail with Dynamic Type (ios-accessibility: non-text dimensions).
    @ScaledMetric(relativeTo: .body) private var thumbnailSize = 56.0

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(path: recipe.coverThumbnailURL, loader: thumbnails)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name).font(.headline)
                Text(recipe.filmSimulation).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if recipe.isFavorite {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recipe.accessibilityDescription)
    }
}
