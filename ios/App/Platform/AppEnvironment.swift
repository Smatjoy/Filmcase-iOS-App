// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// The composition root: the one place the app's dependencies are built. Constructed
/// once in `FilmcaseApp` and passed down; tests build it with in-memory stores.
final class AppEnvironment: Sendable {
    let tokenStore: any TokenStore
    let trust: TrustEvaluator
    let endpoints: ServerEndpoints
    let client: FilmcaseClient
    let endpointSettings: EndpointSettings

    private let pathEvents: any NetworkPathEvents

    init(
        tokenStore: any TokenStore,
        pinStore: any PinStore,
        pathEvents: any NetworkPathEvents,
        endpointSettings: EndpointSettings
    ) {
        let trust = TrustEvaluator(store: pinStore)
        let transport = PinningTransport(evaluator: trust)

        let endpoints = ServerEndpoints(endpoints: endpointSettings.urls(), transport: transport)
        self.tokenStore = tokenStore
        self.trust = trust
        self.endpoints = endpoints
        self.client = FilmcaseClient(endpoints: endpoints, tokenStore: tokenStore, transport: transport)
        self.endpointSettings = endpointSettings
        self.pathEvents = pathEvents
    }

    /// Keychain-backed stores, the real path monitor and `UserDefaults.standard`.
    static func live() -> AppEnvironment {
        AppEnvironment(
            tokenStore: KeychainTokenStore(),
            pinStore: KeychainPinStore(),
            pathEvents: PathMonitorEvents(),
            endpointSettings: EndpointSettings(defaults: .standard)
        )
    }

    /// Keep the endpoint cache honest while the app runs. Call from a `.task` so it is cancelled with the view.
    func observePathChanges() async {
        await endpoints.observe(pathEvents)
    }
}

/// The user's server URLs (LAN first, Tailscale second). Not secret, so UserDefaults.
struct EndpointSettings: Sendable {
    private static let key = "dev.filmcase.endpoints"
    let defaults: UserDefaults

    func urls() -> [URL] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap { URL(string: $0) }
    }

    func save(_ urls: [URL]) {
        defaults.set(urls.map(\.absoluteString), forKey: Self.key)
    }
}
