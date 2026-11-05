import FilmcaseKit
import SwiftUI

struct RecipesTab: View {
    let environment: AppEnvironment

    @State private var path: [Int] = []
    @State private var showsNewRecipe = false

    var body: some View {
        NavigationStack(path: $path) {
            RecipeListView(library: environment.library, thumbnails: environment.thumbnails)
                .navigationTitle("Recipes")
                .navigationDestination(for: Int.self) { id in
                    RecipeDetailView(recipeID: id, environment: environment)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New recipe", systemImage: "plus") { showsNewRecipe = true }
                    }
                }
        }
        .sheet(isPresented: $showsNewRecipe) {
            RecipeEditorView(mode: .create, environment: environment) { id in
                Task { await environment.library.reload() }
                path.append(id)
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
        .onChange(of: library.resultsAnnouncement) { _, text in
            if let text { announce(text) }
        }
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
        .overlay {
            if library.state == .loading {
                ProgressView().accessibilityLabel("Loading recipes")
            }
        }
        .refreshable { await library.refresh() }
    }

    @ViewBuilder
    private var footer: some View {
        if library.isLoadingMore {
            ProgressView()
                .accessibilityLabel("Loading more recipes")
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
        } else if let message = library.loadMoreError {
            VStack(spacing: 8) {
                Text(message).font(.footnote).secondaryText()
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
        // API: AccessibilityTraits.isToggle (iOS 17): announced as a toggle button.
        .accessibilityAddTraits(.isToggle)
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

    // Scales the thumbnail with Dynamic Type (ios-accessibility: non-text dimensions), but
    // capped so it cannot crowd out the text at the largest sizes.
    @ScaledMetric(relativeTo: .body) private var thumbnailSize = 56.0

    var body: some View {
        // Column at accessibility sizes, so the name and film simulation get the full width.
        AdaptiveStack(spacing: 12) {
            ThumbnailView(path: recipe.coverThumbnailURL, loader: thumbnails)
                .frame(width: min(thumbnailSize, 96), height: min(thumbnailSize, 96))
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.displayName).font(.headline)
                Text(recipe.filmSimulation).font(.subheadline).secondaryText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if recipe.isFavorite {
                // Shape, not just colour; the spoken label already says "favourite".
                Image(systemName: "heart.fill").foregroundStyle(.pink).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recipe.accessibilityLabel)
    }
}
