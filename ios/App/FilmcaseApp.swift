import SwiftUI

@main
struct FilmcaseApp: App {
    // Built exactly once, here. `-demo` or the Settings toggle selects the demo flavour.
    @State private var environment: AppEnvironment

    init() {
        let environment = AppEnvironment.launch()
        // Intents run in this process and reach the same environment (composition only).
        AppEnvironment.shared = environment
        _environment = State(initialValue: environment)
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
