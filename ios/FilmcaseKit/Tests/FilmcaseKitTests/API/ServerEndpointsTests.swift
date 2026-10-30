import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FilmcaseKit

private struct ManualPathEvents: NetworkPathEvents {
    let stream: AsyncStream<Void>
    func pathChanges() -> AsyncStream<Void> { stream }
}

@Suite("ServerEndpoints failover")
struct ServerEndpointsTests {
    @Test("LAN healthy: LAN is used and Tailscale is never touched")
    func lanHealthy() async throws {
        let rig = APIRig()
        let active = try await rig.endpoints.activeEndpoint()
        #expect(active == rig.lan.baseURL)
        _ = try await rig.client.recipes()
        #expect(rig.tailscale.requests.isEmpty)
    }

    @Test("the probe is GET /api/v1/recipes/?page_size=1")
    func probeRequest() async throws {
        let rig = APIRig()
        _ = try await rig.endpoints.activeEndpoint()
        let probe = try #require(rig.lan.requests.first)
        #expect(probe.httpMethod == "GET")
        #expect(probe.url?.absoluteString == "https://\(rig.lan.host)/api/v1/recipes/?page_size=1")
    }

    @Test("the healthy endpoint is cached, so it is probed once")
    func cached() async throws {
        let rig = APIRig()
        _ = try await rig.endpoints.activeEndpoint()
        _ = try await rig.endpoints.activeEndpoint()
        _ = try await rig.client.recipes()
        #expect(rig.lan.probes.count == 1)
    }

    @Test("LAN transport error at probe time: Tailscale is used and cached")
    func lanDownAtProbe() async throws {
        let rig = APIRig(lan: { _ in .transportError() })
        #expect(try await rig.endpoints.activeEndpoint() == rig.tailscale.baseURL)
        _ = try await rig.client.recipes()
        _ = try await rig.client.recipes()
        #expect(rig.lan.probes.count == 1)
        #expect(rig.lan.authenticatedRequests.isEmpty)
        #expect(rig.tailscale.authenticatedRequests.count == 2)
        #expect(rig.tailscale.probes.count == 1)
    }

    @Test("a probe that hangs times out on the injected clock and fails over")
    func probeTimeout() async throws {
        let rig = APIRig(lan: { _ in .hang }, probeTimeout: .seconds(3))
        let probing = Task { try await rig.endpoints.activeEndpoint() }
        await rig.clock.waitForSleeps(1)
        #expect(rig.clock.sleeps == [.seconds(3)])
        rig.clock.advance(by: .seconds(3))
        #expect(try await probing.value == rig.tailscale.baseURL)
    }

    @Test("a gateway error at probe time counts as unhealthy")
    func gatewayErrorFailsOver() async throws {
        let rig = APIRig(lan: { _ in .http(status: 502, body: Data()) })
        #expect(try await rig.endpoints.activeEndpoint() == rig.tailscale.baseURL)
    }

    @Test("401 and 503 on the LAN are reachable: no failover, the error surfaces", arguments: [
        (401, "unauthorized"), (503, "serverNotConfigured"),
    ])
    func configurationErrorsDoNotFailOver(_ status: Int, _ kind: String) async throws {
        let rig = APIRig(lan: { _ in .http(status: status, body: Data("{\"error\":\"x\"}".utf8)) })
        #expect(try await rig.endpoints.activeEndpoint() == rig.lan.baseURL)
        let error = await clientError { try await rig.client.recipes() }
        #expect(error?.kind == kind)
        #expect(rig.tailscale.requests.isEmpty)
    }

    @Test("transport error on a request retries once on the next endpoint and updates the cache")
    func transportErrorOnRequest() async throws {
        let rig = APIRig(lan: { request in isProbe(request) ? .fixture("recipe_list") : .transportError(.networkConnectionLost) })
        let page = try await rig.client.recipes()
        #expect(page.count == 2)
        #expect(rig.lan.authenticatedRequests.count == 1)
        #expect(rig.tailscale.authenticatedRequests.count == 1)
        #expect(rig.tailscale.probes.isEmpty)

        _ = try await rig.client.recipes()
        #expect(rig.lan.authenticatedRequests.count == 1)
        #expect(rig.tailscale.authenticatedRequests.count == 2)
    }

    @Test("an HTTP error status on a request never triggers the retry")
    func httpErrorNoRetry() async {
        let rig = APIRig(lan: { request in isProbe(request) ? .fixture("recipe_list") : .fixture("error_404", status: 404) })
        let error = await clientError { try await rig.client.recipe(id: 1) }
        #expect(error?.kind == "notFound")
        #expect(rig.tailscale.requests.isEmpty)
    }

    @Test("both endpoints failing a request is noReachableServer and clears the cache")
    func bothFailOnRequest() async throws {
        let rig = APIRig(
            lan: { request in isProbe(request) ? .fixture("recipe_list") : .transportError() },
            tailscale: { _ in .transportError() }
        )
        let error = await clientError { try await rig.client.recipes() }
        #expect(error?.kind == "noReachableServer")
        #expect(rig.lan.authenticatedRequests.count == 1)
        #expect(rig.tailscale.authenticatedRequests.count == 1)

        // Cache cleared: the next call probes again from the top of the list.
        rig.tailscale.setHandler { _ in .fixture("recipe_list") }
        rig.lan.setHandler { _ in .transportError() }
        #expect(try await rig.endpoints.activeEndpoint() == rig.tailscale.baseURL)
        #expect(rig.lan.probes.count == 2)
    }

    @Test("both endpoints down at probe time is noReachableServer")
    func bothDown() async {
        let rig = APIRig(lan: { _ in .transportError() }, tailscale: { _ in .transportError(.timedOut) })
        let error = await clientError { try await rig.client.recipes() }
        #expect(error?.kind == "noReachableServer")
        #expect(rig.lan.authenticatedRequests.isEmpty)
    }

    @Test("a single endpoint failing is a plain transport error")
    func singleEndpoint() async {
        let server = StubServer(name: "solo", handler: { request in isProbe(request) ? .fixture("recipe_list") : .transportError() })
        let session = StubRegistry.makeSession()
        let endpoints = ServerEndpoints(endpoints: [server.baseURL], session: session, clock: TestClock())
        let client = FilmcaseClient(endpoints: endpoints, tokenStore: InMemoryTokenStore(token: "t"), session: session)
        let error = await clientError { try await client.recipes() }
        #expect(error?.kind == "transport")
    }

    @Test("a path change invalidates the cache and the next call re-probes")
    func pathChangeReprobes() async throws {
        let rig = APIRig()
        #expect(try await rig.endpoints.activeEndpoint() == rig.lan.baseURL)

        // The LAN is gone after the path change (say, the phone left home Wi-Fi).
        rig.lan.setHandler { _ in .transportError(.notConnectedToInternet) }
        await rig.endpoints.pathChanged()

        #expect(try await rig.endpoints.activeEndpoint() == rig.tailscale.baseURL)
        #expect(rig.lan.probes.count == 2)
    }

    @Test("observe() turns each path event into an invalidation")
    func observePathEvents() async throws {
        let rig = APIRig()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let observing = Task { await rig.endpoints.observe(ManualPathEvents(stream: stream)) }

        _ = try await rig.endpoints.activeEndpoint()
        continuation.yield()
        continuation.finish()
        await observing.value

        _ = try await rig.endpoints.activeEndpoint()
        #expect(rig.lan.probes.count == 2)
    }

    @Test("a pin mismatch at probe time stops the search instead of failing over")
    func pinMismatchAtProbe() async {
        let rig = APIRig(lan: { _ in
            .failure(URLError(.serverCertificateUntrusted, userInfo: [NSUnderlyingErrorKey: PinMismatchError(host: "lan.test")]))
        })
        let error = await clientError { try await rig.endpoints.activeEndpoint() }
        #expect(error?.kind == "pinMismatch")
        #expect(rig.tailscale.requests.isEmpty)
    }

    @Test("an unpinned host at probe time stops the search and carries the fingerprint")
    func unpinnedAtProbe() async {
        let rig = APIRig(lan: { _ in
            .failure(URLError(.serverCertificateUntrusted, userInfo: [
                NSUnderlyingErrorKey: UnpinnedHostError(host: "lan.test", fingerprint: "abcd"),
            ]))
        })
        let error = await clientError { try await rig.endpoints.activeEndpoint() }
        guard case let .unpinnedHost(host, fingerprint)? = error else {
            Issue.record("expected unpinnedHost, got \(String(describing: error))")
            return
        }
        #expect(host == "lan.test")
        #expect(fingerprint == "abcd")
        #expect(rig.tailscale.requests.isEmpty)
    }

    @Test("update(endpoints:) replaces the order and forgets the cache")
    func updateEndpoints() async throws {
        let rig = APIRig()
        #expect(try await rig.endpoints.activeEndpoint() == rig.lan.baseURL)
        await rig.endpoints.update(endpoints: [rig.tailscale.baseURL, rig.lan.baseURL])
        #expect(try await rig.endpoints.activeEndpoint() == rig.tailscale.baseURL)
    }

    @Test("a base URL with a path prefix keeps it")
    func pathPrefix() {
        let url = apiURL(URL(string: "https://host.test/filmcase/")!, path: "/api/v1/recipes/", query: [URLQueryItem(name: "page_size", value: "1")])
        #expect(url.absoluteString == "https://host.test/filmcase/api/v1/recipes/?page_size=1")
    }
}
