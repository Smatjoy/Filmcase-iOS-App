import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Facet selections and name search for the recipe list, mirroring the explorer's
/// query parameters (`film_simulation=Provia&film_simulation=...`, `name_search=`).
public struct RecipeFilters: Sendable, Equatable {
    public var nameSearch: String
    /// Facet field name (a key of `RecipePage.facets`) to the selected values.
    public var facets: [String: [String]]

    public init(nameSearch: String = "", facets: [String: [String]] = [:]) {
        self.nameSearch = nameSearch
        self.facets = facets
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !nameSearch.isEmpty { items.append(URLQueryItem(name: "name_search", value: nameSearch)) }
        for field in facets.keys.sorted() {
            for value in facets[field] ?? [] { items.append(URLQueryItem(name: field, value: value)) }
        }
        return items
    }
}

/// Typed access to the read-only `/api/v1/` API.
///
/// Every request carries `Authorization: Bearer <token>` and goes to the endpoint
/// `ServerEndpoints` currently considers active. On a transport error it retries
/// once on the next endpoint (updating the cache); if that fails too the result is
/// `.noReachableServer`. HTTP error statuses never fail over.
public struct FilmcaseClient: Sendable {
    private let endpoints: ServerEndpoints
    private let tokenStore: any TokenStore
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(
        endpoints: ServerEndpoints,
        tokenStore: any TokenStore,
        session: URLSession,
        requestTimeout: TimeInterval = 30
    ) {
        self.endpoints = endpoints
        self.tokenStore = tokenStore
        self.session = session
        self.requestTimeout = requestTimeout
    }

    public func recipes(
        page: Int = 1,
        pageSize: Int = 24,
        filters: RecipeFilters = RecipeFilters(),
        favoritesOnly: Bool = false
    ) async throws -> RecipePage {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
        ] + filters.queryItems
        if favoritesOnly { query.append(URLQueryItem(name: "favorite", value: "true")) }
        return try await decode(RecipePage.self, from: "/api/v1/recipes/", query: query)
    }

    public func recipe(id: Int) async throws -> RecipeDetail {
        try await decode(RecipeDetail.self, from: "/api/v1/recipes/\(id)/")
    }

    public func collections() async throws -> CollectionList {
        try await decode(CollectionList.self, from: "/api/v1/collections/")
    }

    public func collection(id: Int) async throws -> CollectionDetail {
        try await decode(CollectionDetail.self, from: "/api/v1/collections/\(id)/")
    }

    /// The JPEG bytes of an image's thumbnail.
    public func thumbnailData(imageId: Int) async throws -> Data {
        try await get("/api/v1/images/\(imageId)/thumbnail")
    }

    /// The camera client config JSON (property encodings, slot counts), unparsed.
    public func cameraClientConfig() async throws -> Data {
        try await get("/api/v1/camera/client-config.json")
    }

    /// The camera payload JSON for a recipe, unparsed.
    public func cameraPayload(recipeId: Int) async throws -> Data {
        try await get("/api/v1/recipes/\(recipeId)/camera-payload.json")
    }

    // MARK: - Plumbing

    private func decode<T: Decodable>(_ type: T.Type, from path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await get(path, query: query)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw FilmcaseClientError.decoding(String(describing: error))
        }
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let token = try await tokenStore.token(), !token.isEmpty else {
            throw FilmcaseClientError.unauthorized
        }
        let base = try await endpoints.activeEndpoint()
        do {
            return try await send(to: base, path: path, query: query, token: token)
        } catch FilmcaseClientError.transport(let firstError) {
            guard let next = await endpoints.endpoint(afterFailureOf: base) else {
                throw FilmcaseClientError.transport(firstError)
            }
            do {
                return try await send(to: next, path: path, query: query, token: token)
            } catch FilmcaseClientError.transport {
                await endpoints.invalidate()
                throw FilmcaseClientError.noReachableServer
            }
        }
    }

    private func send(to base: URL, path: String, query: [URLQueryItem], token: String) async throws -> Data {
        var request = URLRequest(url: apiURL(base, path: path, query: query))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if isCancellation(error) { throw CancellationError() }
            throw FilmcaseClientError.fromTransport(error, host: base.host() ?? "")
        }
        guard let http = response as? HTTPURLResponse else {
            throw FilmcaseClientError.transport(URLError(.badServerResponse))
        }
        if let failure = FilmcaseClientError.forStatus(http.statusCode, body: data) { throw failure }
        return data
    }
}
