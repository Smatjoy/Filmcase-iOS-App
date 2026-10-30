// Where the camera's encoding tables come from (ADR 016, "encoding tables are served, not
// duplicated"): the server's /api/v1/camera/client-config.json when it can be reached, else the
// copy cached from the last time it was, else the snapshot bundled in the app. The snapshot
// exists so a camera can be used before any server has answered; a test pins its encodings to
// the shared golden vectors so it cannot drift silently.

import Foundation

/// Where a loaded `ClientConfig` came from.
public enum ClientConfigSource: Equatable, Sendable {
    /// Fetched from the server just now.
    case served
    /// The copy saved from an earlier fetch.
    case cached
    /// The snapshot shipped with the app.
    case bundled
}

/// Keeps the last served config body so it survives a server that cannot be reached.
/// The app supplies a file-backed one; `InMemoryClientConfigCache` serves tests and demo.
public protocol ClientConfigCache: Sendable {
    /// The stored JSON body, or nil when nothing is stored.
    func load() async -> Data?
    func store(_ data: Data) async
}

public actor InMemoryClientConfigCache: ClientConfigCache {
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func load() async -> Data? { data }

    public func store(_ data: Data) async { self.data = data }
}

/// The current client config: served, else cached, else *bundledSnapshot*. Never throws: a
/// server that is down, a rejected token or a body that does not decode all fall back, and
/// only a body that decodes is cached.
public func loadClientConfig(
    client: FilmcaseClient, cache: any ClientConfigCache, bundledSnapshot: ClientConfig
) async -> (config: ClientConfig, source: ClientConfigSource) {
    if let body = try? await client.cameraClientConfig(),
       let served = try? JSONDecoder().decode(ClientConfig.self, from: body) {
        await cache.store(body)
        return (served, .served)
    }
    if let body = await cache.load(), let cached = try? JSONDecoder().decode(ClientConfig.self, from: body) {
        return (cached, .cached)
    }
    return (bundledSnapshot, .bundled)
}
