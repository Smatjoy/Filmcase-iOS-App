import SwiftUI

@main
struct FilmcaseApp: App {
    // Built exactly once, here.
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
