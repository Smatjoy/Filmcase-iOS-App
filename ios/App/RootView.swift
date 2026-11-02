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
                RecipesTab(environment: environment)
            }
            Tab("Collections", systemImage: "rectangle.stack", value: AppTab.collections) {
                CollectionsTab(environment: environment)
            }
            Tab("Camera", systemImage: "camera", value: AppTab.camera) {
                NavigationStack {
                    CameraTab(environment: environment)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab(environment: environment)
            }
        }
        // API: tabBarMinimizeBehavior(_:) (iOS 26, iPhone only): the bar shrinks on scroll.
        .tabBarMinimizeBehavior(.onScrollDown)
        // API: tabViewBottomAccessory(content:) (iOS 26): a persistent camera pill above the tab bar.
        .tabViewBottomAccessory {
            ConnectionPillButton(model: environment.cameraModel) { selection = .camera }
        }
        // A camera connecting or dropping happens off-screen from the user's point of view
        // (cable plugged in), so say it aloud wherever VoiceOver focus is.
        .onChange(of: environment.cameraModel.pill) { _, pill in
            announce(pill.text)
        }
        .task { await environment.observePathChanges() }
        .task { await environment.observeCamera() }
        .task {
            showsOnboarding = await environment.needsOnboarding()
            // Onboarding ends in reloadServerContent(), which refreshes the config itself.
            if !showsOnboarding { await environment.refreshCameraConfig() }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView(environment: environment, onCancel: nil) {
                showsOnboarding = false
                Task { await environment.reloadServerContent() }
            }
            .interactiveDismissDisabled()
        }
    }
}
