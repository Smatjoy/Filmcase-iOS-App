import SwiftUI

enum AppTab: Hashable {
    case recipes, collections, camera, settings
}

struct RootView: View {
    let environment: AppEnvironment

    @State private var selection: AppTab = .recipes
    @State private var showsOnboarding = false

    var body: some View {
        TabView(selection: $selection) {
            Tab("Recipes", systemImage: "camera.filters", value: AppTab.recipes) {
                NavigationStack {
                    PlaceholderView(title: "Recipes", detail: "Browse, search and filter your film simulation recipes.")
                }
            }
            Tab("Collections", systemImage: "rectangle.stack", value: AppTab.collections) {
                NavigationStack {
                    PlaceholderView(title: "Collections", detail: "Your recipe collections and their C1-C7 slot order.")
                }
            }
            Tab("Camera", systemImage: "camera", value: AppTab.camera) {
                NavigationStack {
                    PlaceholderView(title: "Camera", detail: "Connection status and sending recipes to camera slots.")
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    PlaceholderView(title: "Settings", detail: "Servers, token and pinned certificates.")
                }
            }
        }
        .task { await environment.observePathChanges() }
        .task { showsOnboarding = await OnboardingState.needsOnboarding(in: environment) }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(state: OnboardingState(environment: environment)) {
                showsOnboarding = false
            }
            .interactiveDismissDisabled()
        }
    }
}

struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text(detail))
            .navigationTitle(title)
    }
}
