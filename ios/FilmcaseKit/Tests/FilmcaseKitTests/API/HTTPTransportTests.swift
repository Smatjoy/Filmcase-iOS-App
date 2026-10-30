import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import FilmcaseKit

/// A transport that is not a URLSession, as the app's pinning transport is not:
/// probes succeed, requests throw a scripted error directly.
private final class ScriptedTransport: HTTPTransport {
    private let requestError: any Error
    private let calls = Mutex<[URL]>([])

    init(requestError: any Error) {
        self.requestError = requestError
    }

    var requested: [URL] { calls.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        calls.withLock { $0.append(url) }
        if request.value(forHTTPHeaderField: "Authorization") == nil {
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        throw requestError
    }
}

@Suite("HTTPTransport")
struct HTTPTransportTests {
    private let lan = URL(string: "https://lan.test")!
    private let tailscale = URL(string: "https://tailscale.test")!

    private func client(_ transport: ScriptedTransport) -> FilmcaseClient {
        let endpoints = ServerEndpoints(endpoints: [lan, tailscale], transport: transport, clock: TestClock())
        return FilmcaseClient(endpoints: endpoints, tokenStore: InMemoryTokenStore(token: "t"), transport: transport)
    }

    @Test("a pin error thrown directly by the transport is reported and does not fail over")
    func directPinError() async {
        let transport = ScriptedTransport(requestError: UnpinnedHostError(host: "lan.test", fingerprint: "ab"))
        let error = await clientError { try await client(transport).recipes() }
        guard case let .unpinnedHost(host, fingerprint)? = error else {
            Issue.record("expected unpinnedHost, got \(String(describing: error))")
            return
        }
        #expect(host == "lan.test")
        #expect(fingerprint == "ab")
        #expect(!transport.requested.contains { $0.host() == "tailscale.test" })
    }

    @Test("a plain transport error still fails over")
    func transportErrorFailsOver() async {
        let transport = ScriptedTransport(requestError: URLError(.networkConnectionLost))
        _ = await clientError { try await client(transport).recipes() }
        #expect(transport.requested.contains { $0.host() == "tailscale.test" })
    }
}
