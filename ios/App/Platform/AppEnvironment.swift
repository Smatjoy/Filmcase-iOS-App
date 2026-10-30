// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// UserDefaults keys the app owns. Outside `AppEnvironment` so reading them needs no actor hop.
enum AppDefaults {
    /// Settings toggle; applied on the next launch.
    static let demoModeKey = "dev.filmcase.demoMode"
    /// Launch argument that forces demo mode (CI UI test, screenshots).
    static let demoLaunchArgument = "-demo"
}

/// The composition root: the one place the app's dependencies and view models are built.
/// Constructed once in `FilmcaseApp` and passed down; tests build it with in-memory stores.
///
/// Surface for the camera features (P7): `client`, `connection`, `cameraModel`,
/// `cameraRuntime`, `cameraConfig`, `backupStore`, `thumbnails`.
@MainActor
final class AppEnvironment {
    /// Which `CameraTransport` backs the camera connection.
    enum CameraMode: Sendable, Equatable {
        /// A scripted X-T50 with seven named slots; no hardware.
        case demo
        /// ImageCaptureCore over USB-C (P5; a placeholder until then).
        case usb
    }

    let cameraMode: CameraMode
    let tokenStore: any TokenStore
    let trust: TrustEvaluator
    let endpoints: ServerEndpoints
    let client: FilmcaseClient
    let endpointSettings: EndpointSettings

    /// The bundled snapshot of `/camera/client-config.json`. The connection needs the slot-cursor
    /// code before any server has answered, so the snapshot is what it is built with.
    let cameraConfig: ClientConfig
    let cameraRuntime: CameraRuntime
    let connection: CameraConnection
    let backupStore: any BackupStore

    let library: LibraryModel
    let collections: CollectionsModel
    let cameraModel: CameraModel
    let thumbnails: ThumbnailLoader

    private let pathEvents: any NetworkPathEvents

    init(
        tokenStore: any TokenStore,
        pinStore: any PinStore,
        pathEvents: any NetworkPathEvents,
        endpointSettings: EndpointSettings,
        cameraMode: CameraMode = .usb,
        httpTransport: (any HTTPTransport)? = nil,
        cameraConfig: ClientConfig = AppEnvironment.bundledCameraConfig()
    ) {
        let trust = TrustEvaluator(store: pinStore)
        let transport: any HTTPTransport = httpTransport ?? PinningTransport(evaluator: trust)
        let endpoints = ServerEndpoints(endpoints: endpointSettings.urls(), transport: transport)
        let client = FilmcaseClient(endpoints: endpoints, tokenStore: tokenStore, transport: transport)
        let connection = CameraConnection(
            transport: makeCameraTransport(mode: cameraMode, config: cameraConfig), config: cameraConfig)
        let runtime = CameraRuntime(config: cameraConfig, clock: SystemClock())

        self.cameraMode = cameraMode
        self.tokenStore = tokenStore
        self.trust = trust
        self.endpoints = endpoints
        self.client = client
        self.endpointSettings = endpointSettings
        self.pathEvents = pathEvents
        self.cameraConfig = cameraConfig
        self.cameraRuntime = runtime
        self.connection = connection
        self.backupStore = InMemoryBackupStore() // TODO(P7/persistence): SwiftData adapter
        self.library = LibraryModel(client: client)
        self.collections = CollectionsModel(client: client)
        self.cameraModel = CameraModel(connection: connection, runtime: runtime)
        self.thumbnails = ThumbnailLoader(client: client)
    }

    // --- launch flavours ---

    /// Demo when launched with `-demo` or when the Settings toggle was on; otherwise live.
    static func launch(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> AppEnvironment {
        let wantsDemo = arguments.contains(AppDefaults.demoLaunchArgument)
            || defaults.bool(forKey: AppDefaults.demoModeKey)
        return wantsDemo ? demo() : live()
    }

    /// Keychain-backed stores, the real path monitor and `UserDefaults.standard`.
    static func live() -> AppEnvironment {
        AppEnvironment(
            tokenStore: KeychainTokenStore(),
            pinStore: KeychainPinStore(),
            pathEvents: PathMonitorEvents(),
            endpointSettings: EndpointSettings(defaults: .standard),
            cameraMode: .usb
        )
    }

    /// Bundled JSON for the server, a scripted camera, in-memory stores. Needs no onboarding:
    /// the token and the one endpoint are already set.
    static func demo() -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "dev.filmcase.demo") ?? .standard
        let settings = EndpointSettings(defaults: defaults)
        settings.save([DemoHTTPTransport.baseURL])
        return AppEnvironment(
            tokenStore: InMemoryTokenStore(token: "demo"),
            pinStore: InMemoryPinStore(),
            pathEvents: IdlePathEvents(),
            endpointSettings: settings,
            cameraMode: .demo,
            httpTransport: DemoHTTPTransport()
        )
    }

    static func bundledCameraConfig(bundle: Bundle = .main) -> ClientConfig {
        guard let url = bundle.url(forResource: "camera_client_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ClientConfig.self, from: data)
        else { fatalError("camera_client_config.json is missing from the app bundle") }
        return config
    }

    // --- intents the views forward ---

    var modeDescription: String {
        switch cameraMode {
        case .demo: "Demo (bundled data, simulated camera)"
        case .usb: "Live"
        }
    }

    func needsOnboarding() async -> Bool {
        await OnboardingModel.needsOnboarding(tokenStore: tokenStore, endpoints: endpoints)
    }

    func makeOnboardingModel() -> OnboardingModel {
        OnboardingModel(
            tokenStore: tokenStore, endpoints: endpoints, client: client, trust: trust,
            settings: endpointSettings)
    }

    func makeRecipeDetailModel(id: Int) -> RecipeDetailModel {
        RecipeDetailModel(
            recipeID: id, client: client,
            camera: RunnerCameraSource(runner: connection, encodings: cameraConfig.encodings))
    }

    /// Reload what depends on the server after the servers or token changed.
    func reloadServerContent() async {
        await library.reload()
        await collections.load()
    }

    func forgetCertificate(host: String) async throws {
        try await trust.forget(host: host)
    }

    /// Follow the camera connection; run from a `.task` so it ends with the view.
    func observeCamera() async {
        await cameraModel.observe()
    }

    /// Keep the endpoint cache honest while the app runs. Call from a `.task` so it is cancelled with the view.
    func observePathChanges() async {
        await endpoints.observe(pathEvents)
    }
}

extension AppEnvironment: CameraFeatureEnvironment {
    var clock: any FilmcaseClock { SystemClock() }
}

/// The user's server URLs (LAN first, Tailscale second). Not secret, so UserDefaults.
struct EndpointSettings: EndpointSettingsStore {
    private static let key = "dev.filmcase.endpoints"
    let defaults: UserDefaults

    func urls() -> [URL] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap { URL(string: $0) }
    }

    func save(_ urls: [URL]) {
        defaults.set(urls.map(\.absoluteString), forKey: Self.key)
    }
}
