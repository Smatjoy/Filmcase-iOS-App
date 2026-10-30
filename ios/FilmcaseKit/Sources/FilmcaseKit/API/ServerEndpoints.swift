import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Emits a value whenever the device's network path changes (Wi-Fi to cellular,
/// VPN up or down, ...). The app adapts `NWPathMonitor` to this; tests use a
/// hand-driven stream.
public protocol NetworkPathEvents: Sendable {
    func pathChanges() -> AsyncStream<Void>
}

/// The ordered list of server base URLs (LAN first, Tailscale second, as the user
/// ordered them) and which one is currently in use.
///
/// `activeEndpoint()` probes in order with `GET /api/v1/recipes/?page_size=1` and
/// caches the first that answers. Any HTTP answer other than a gateway failure
/// counts as reachable, including 401 and 503: that is the right server with the
/// wrong configuration, and failing over would hide the real problem. A pin
/// mismatch also stops the search and is thrown, because silently trying another
/// host after a certificate change would defeat the pin.
public actor ServerEndpoints {
    public private(set) var endpoints: [URL]
    private let session: URLSession
    private let probeTimeout: Duration
    private let clock: any Clock
    private var cached: URL?
    private var generation = 0

    public init(
        endpoints: [URL],
        session: URLSession,
        probeTimeout: Duration = .seconds(2),
        clock: any Clock = SystemClock()
    ) {
        self.endpoints = endpoints
        self.session = session
        self.probeTimeout = probeTimeout
        self.clock = clock
    }

    /// The endpoint to use now, probing if nothing is cached.
    /// - Throws: `.noReachableServer` if none answers, `.pinMismatch` if one presents a changed certificate.
    public func activeEndpoint() async throws -> URL {
        if let cached { return cached }
        let startedAt = generation
        for endpoint in endpoints {
            if try await probe(endpoint) {
                if generation == startedAt { cached = endpoint }
                return endpoint
            }
        }
        throw FilmcaseClientError.noReachableServer
    }

    /// Replace the list (the user reordered or edited the servers) and forget the cache.
    public func update(endpoints: [URL]) {
        self.endpoints = endpoints
        pathChanged()
    }

    /// The network path changed: the cached endpoint may no longer be the best, or reachable.
    public func pathChanged() {
        generation += 1
        cached = nil
    }

    /// Consume *events* until its stream finishes, invalidating the cache on each change.
    /// Run it in a task the app owns: `Task { await endpoints.observe(monitor) }`.
    public func observe(_ events: some NetworkPathEvents) async {
        for await _ in events.pathChanges() {
            pathChanged()
        }
    }

    /// A request to *failed* hit a transport error. Returns the endpoint to retry
    /// on, the next one in order (wrapping), and makes it the cached one. Returns
    /// nil if there is no other endpoint. If another request already moved the
    /// cache off *failed*, that endpoint is returned instead.
    func endpoint(afterFailureOf failed: URL) -> URL? {
        if let cached, cached != failed { return cached }
        guard let index = endpoints.firstIndex(of: failed), endpoints.count > 1 else { return nil }
        let next = endpoints[(index + 1) % endpoints.count]
        cached = next
        return next
    }

    /// Forget the cache after the retry failed too.
    func invalidate() {
        pathChanged()
    }

    private func probe(_ base: URL) async throws -> Bool {
        let request = URLRequest(url: apiURL(base, path: "/api/v1/recipes/", query: [URLQueryItem(name: "page_size", value: "1")]))
        let session = session
        do {
            let (_, response) = try await withTimeout(probeTimeout, clock: clock) {
                try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode != 502 && http.statusCode != 504 && (http.statusCode < 500 || http.statusCode == 503)
        } catch {
            if isCancellation(error) { throw CancellationError() }
            if case .pinMismatch = FilmcaseClientError.fromTransport(error, host: base.host() ?? "") {
                throw FilmcaseClientError.fromTransport(error, host: base.host() ?? "")
            }
            return false
        }
    }
}

/// *base* with *path* appended to its own path (so a server mounted under a prefix works).
func apiURL(_ base: URL, path: String, query: [URLQueryItem] = []) -> URL {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
    var prefix = components.path
    while prefix.hasSuffix("/") { prefix.removeLast() }
    components.path = prefix + path
    components.queryItems = query.isEmpty ? nil : query
    return components.url ?? base
}

/// Run *operation*, failing with `URLError(.timedOut)` if *timeout* elapses first on *clock*.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    clock: any Clock,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await clock.sleep(for: timeout)
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw URLError(.unknown) }
        return first
    }
}
