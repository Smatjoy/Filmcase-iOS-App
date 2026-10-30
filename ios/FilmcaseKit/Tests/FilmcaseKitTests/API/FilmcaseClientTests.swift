import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FilmcaseKit

/// Foundation on Linux drops a trailing slash from `URL.path`; compare without it everywhere.
private func trimmedPath(_ url: URL) -> String {
    var path = url.path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
}

private func route(_ routes: [String: StubReply], fallback: StubReply = .fixture("error_404", status: 404)) -> @Sendable (URLRequest) -> StubReply {
    { request in routes[request.url.map(trimmedPath) ?? ""] ?? fallback }
}

@Suite("FilmcaseClient")
struct FilmcaseClientTests {
    @Test("sends the bearer token on every request")
    func bearerHeader() async throws {
        let rig = APIRig()
        _ = try await rig.client.recipes()
        _ = try await rig.client.recipes(page: 2)
        let requests = rig.lan.authenticatedRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(APIRig.token)" })
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test("recipes builds page, page size and filter parameters")
    func recipesQuery() async throws {
        let rig = APIRig()
        let filters = RecipeFilters(nameSearch: "portra", facets: ["film_simulation": ["Provia", "Classic Chrome"], "sensors": ["X-Trans V"]])
        let page = try await rig.client.recipes(page: 3, pageSize: 10, filters: filters)
        #expect(page.count == 2)
        let url = try #require(rig.lan.authenticatedRequests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { "\($0.name)=\($0.value ?? "")" }
        #expect(items == [
            "page=3", "page_size=10", "name_search=portra",
            "film_simulation=Provia", "film_simulation=Classic Chrome", "sensors=X-Trans V",
        ])
        #expect(url.absoluteString.hasPrefix("https://\(rig.lan.host)/api/v1/recipes/?page=3"))
    }

    @Test("favoritesOnly sends favorite=true")
    func favoritesOnly() async throws {
        let rig = APIRig(lan: { _ in .fixture("recipe_list_favorites") })
        let page = try await rig.client.recipes(favoritesOnly: true)
        #expect(page.results.allSatisfy { $0.isFavorite })
        let url = try #require(rig.lan.authenticatedRequests.first?.url)
        #expect(url.query?.contains("favorite=true") == true)
        _ = try await rig.client.recipes()
        let plain = try #require(rig.lan.authenticatedRequests.last?.url)
        #expect(plain.query?.contains("favorite") == false)
    }

    @Test("every endpoint hits its path and decodes")
    func endpoints() async throws {
        let detail = try Fixture.decode(RecipeDetail.self, "recipe_detail")
        let collection = try Fixture.decode(CollectionDetail.self, "collection_detail")
        let thumbnail = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let rig = APIRig(lan: route([
            "/api/v1/recipes": .fixture("recipe_list"),
            "/api/v1/recipes/\(detail.id)": .fixture("recipe_detail"),
            "/api/v1/collections": .fixture("collection_list"),
            "/api/v1/collections/\(collection.id)": .fixture("collection_detail"),
            "/api/v1/images/7/thumbnail": .http(status: 200, body: thumbnail, headers: ["Content-Type": "image/jpeg"]),
            "/api/v1/camera/client-config.json": .fixture("camera_client_config"),
            "/api/v1/recipes/\(detail.id)/camera-payload.json": .fixture("camera_payload"),
        ]))

        #expect(try await rig.client.recipes().results.count == 2)
        #expect(try await rig.client.recipe(id: detail.id) == detail)
        #expect(try await rig.client.collections().count == 2)
        #expect(try await rig.client.collection(id: collection.id) == collection)
        #expect(try await rig.client.thumbnailData(imageId: 7) == thumbnail)
        #expect(try await rig.client.cameraClientConfig() == Fixture.data("camera_client_config"))
        #expect(try await rig.client.cameraPayload(recipeId: detail.id) == Fixture.data("camera_payload"))
    }

    @Test("maps error statuses to typed errors", arguments: [
        (401, "unauthorized"), (503, "serverNotConfigured"), (404, "notFound"),
        (400, "badRequest"), (500, "unexpectedStatus"), (405, "unexpectedStatus"),
    ])
    func statusMapping(_ status: Int, _ kind: String) async {
        let rig = APIRig(lan: { request in
            isProbe(request) ? .fixture("recipe_list") : .http(status: status, body: Data("{\"error\":\"x\"}".utf8))
        })
        let error = await clientError { try await rig.client.recipe(id: 1) }
        #expect(error?.kind == kind)
    }

    @Test("a 400 carries the server's message")
    func badRequestMessage() async {
        let rig = APIRig(lan: { _ in .fixture("error_400", status: 400) })
        let error = await clientError { try await rig.client.recipes() }
        guard case let .badRequest(message)? = error else {
            Issue.record("expected badRequest, got \(String(describing: error))")
            return
        }
        #expect(message == "page must be a positive integer.")
    }

    @Test("the recorded 401, 503 and 404 bodies map the same way")
    func recordedErrors() async {
        for (status, name, kind) in [(401, "error_401", "unauthorized"), (503, "error_503", "serverNotConfigured"), (404, "error_404", "notFound")] {
            let rig = APIRig(lan: { _ in .fixture(name, status: status) })
            let error = await clientError { try await rig.client.collections() }
            #expect(error?.kind == kind)
        }
    }

    @Test("a 2xx body that does not match the DTO is a decoding error")
    func decodingError() async {
        let rig = APIRig(lan: { _ in .fixture("collection_list") })
        let error = await clientError { try await rig.client.recipes() }
        #expect(error?.kind == "decoding")
    }

    @Test("without a stored token it fails as unauthorized and sends nothing")
    func noToken() async {
        let rig = APIRig(token: nil)
        let error = await clientError { try await rig.client.recipes() }
        #expect(error?.kind == "unauthorized")
        #expect(rig.lan.requests.isEmpty)
        #expect(rig.tailscale.requests.isEmpty)
    }

    @Test("a pin mismatch surfaces with the host and does not fail over")
    func pinMismatchOnRequest() async {
        let lan = StubServer(name: "pinned")
        let tailscale = StubServer(name: "other", handler: { _ in .fixture("recipe_list") })
        lan.setHandler { request in
            isProbe(request)
                ? .fixture("recipe_list")
                : .failure(URLError(.serverCertificateUntrusted, userInfo: [NSUnderlyingErrorKey: PinMismatchError(host: "pinned.test")]))
        }
        let session = StubRegistry.makeSession()
        let endpoints = ServerEndpoints(endpoints: [lan.baseURL, tailscale.baseURL], session: session, clock: TestClock())
        let client = FilmcaseClient(endpoints: endpoints, tokenStore: InMemoryTokenStore(token: "t"), session: session)

        let error = await clientError { try await client.recipes() }

        guard case let .pinMismatch(host: host)? = error else {
            Issue.record("expected pinMismatch, got \(String(describing: error))")
            return
        }
        #expect(host == "pinned.test")
        #expect(tailscale.authenticatedRequests.isEmpty)
    }
}
