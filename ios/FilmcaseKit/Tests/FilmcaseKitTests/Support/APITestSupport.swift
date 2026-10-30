import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

/// Recorded API responses, read from API/Fixtures next to the tests.
enum Fixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("API/Fixtures")

    static func data(_ name: String) -> Data {
        let url = directory.appendingPathComponent("\(name).json")
        do {
            return try Data(contentsOf: url)
        } catch {
            fatalError("Missing fixture \(url.path): \(error)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

extension FilmcaseClientError {
    /// A comparable name for the case, ignoring payloads.
    var kind: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .serverNotConfigured: "serverNotConfigured"
        case .notFound: "notFound"
        case .badRequest: "badRequest"
        case .unexpectedStatus: "unexpectedStatus"
        case .transport: "transport"
        case .decoding: "decoding"
        case .pinMismatch: "pinMismatch"
        case .noReachableServer: "noReachableServer"
        }
    }
}

/// Run *operation* and return the `FilmcaseClientError` it threw, or nil if it succeeded or threw something else.
func clientError(_ operation: () async throws -> some Any) async -> FilmcaseClientError? {
    do {
        _ = try await operation()
        return nil
    } catch let error as FilmcaseClientError {
        return error
    } catch {
        return nil
    }
}

func isProbe(_ request: URLRequest) -> Bool {
    request.value(forHTTPHeaderField: "Authorization") == nil
}

/// A LAN server, a Tailscale server and a client over both, with a manual clock.
struct APIRig {
    let lan: StubServer
    let tailscale: StubServer
    let clock: TestClock
    let endpoints: ServerEndpoints
    let client: FilmcaseClient
    let tokenStore: InMemoryTokenStore

    static let token = "fixture-token"

    init(
        lan: @escaping @Sendable (URLRequest) -> StubReply = { _ in .fixture("recipe_list") },
        tailscale: @escaping @Sendable (URLRequest) -> StubReply = { _ in .fixture("recipe_list") },
        token: String? = APIRig.token,
        probeTimeout: Duration = .seconds(2)
    ) {
        self.lan = StubServer(name: "lan", handler: lan)
        self.tailscale = StubServer(name: "tailscale", handler: tailscale)
        clock = TestClock()
        let session = StubRegistry.makeSession()
        endpoints = ServerEndpoints(
            endpoints: [self.lan.baseURL, self.tailscale.baseURL],
            session: session,
            probeTimeout: probeTimeout,
            clock: clock
        )
        tokenStore = InMemoryTokenStore(token: token)
        client = FilmcaseClient(endpoints: endpoints, tokenStore: tokenStore, session: session)
    }
}
