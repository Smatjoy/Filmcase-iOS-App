// The one place that answers "which CameraRuntime is current?". It starts from the bundled
// snapshot, so a camera works at once, and swaps in the served (or cached) config when
// `refresh()` has loaded one, for example at launch and whenever the server settings change.
// Callers ask for the runtime when they start work and use it for that whole piece of work, so
// a refresh never changes encodings halfway through a push.

import Foundation

/// Something that can hand out the runtime to use right now. A plain `CameraRuntime` is its
/// own source (a fixed one, for tests and previews).
public protocol CameraRuntimeSource: Sendable {
    func currentRuntime() async -> CameraRuntime
}

extension CameraRuntime: CameraRuntimeSource {
    public func currentRuntime() async -> CameraRuntime { self }
}

public actor CameraRuntimeProvider: CameraRuntimeSource {
    private let client: FilmcaseClient
    private let cache: any ClientConfigCache
    private let sleeper: any CameraSleeper
    private var runtime: CameraRuntime
    private var configSource: ClientConfigSource = .bundled
    private var refreshGeneration = 0

    /// - Parameters:
    ///   - bundledSnapshot: Used until `refresh()` finds something better.
    ///   - sleeper: Where the runtime's delays go (`SystemCameraSleeper` in the app).
    public init(
        client: FilmcaseClient, cache: any ClientConfigCache, bundledSnapshot: ClientConfig,
        sleeper: any CameraSleeper = SystemCameraSleeper()
    ) {
        self.client = client
        self.cache = cache
        self.sleeper = sleeper
        self.runtime = CameraRuntime(config: bundledSnapshot, sleeper: sleeper)
    }

    /// The runtime to use for the next piece of work.
    public func currentRuntime() -> CameraRuntime { runtime }

    /// Where the current config came from.
    public var source: ClientConfigSource { configSource }

    /// Load the config again (served, else cached, else keep what is current) and switch to it.
    /// A refresh that finds nothing better than the bundled snapshot never replaces a config
    /// that was already served or cached. Returns where the config now in use came from.
    @discardableResult
    public func refresh() async -> ClientConfigSource {
        refreshGeneration += 1
        let token = refreshGeneration
        let loaded = await loadClientConfig(client: client, cache: cache, bundledSnapshot: runtime.config)
        // A newer refresh started while this one was loading: its answer wins.
        guard token == refreshGeneration else { return configSource }
        if loaded.source == .bundled, configSource != .bundled { return configSource }
        runtime = CameraRuntime(config: loaded.config, sleeper: sleeper)
        configSource = loaded.source
        return loaded.source
    }
}
