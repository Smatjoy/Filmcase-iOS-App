import SwiftUI

@main
struct FilmcaseApp: App {
    // Built exactly once, here. `-demo` or the Settings toggle selects the demo flavour.
    @State private var environment = AppEnvironment.launch()

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
