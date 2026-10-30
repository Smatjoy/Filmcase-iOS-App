// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// Serves the JSON recorded from the real API (Demo/Fixtures, copied from the FilmcaseKit
// test fixtures) so the app runs, and the CI UI test passes, without a server.

import FilmcaseKit
import Foundation

struct DemoHTTPTransport: HTTPTransport {
    static let baseURL = URL(string: "https://demo.filmcase.invalid")!

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let favoritesOnly = query.contains { $0.name == "favorite" && $0.value == "true" }
        let fixture = Self.fixture(for: parts, favoritesOnly: favoritesOnly)
        guard let fileURL = bundle.url(forResource: fixture ?? "error_404", withExtension: "json") else {
            throw URLError(.fileDoesNotExist)
        }
        let data = try Data(contentsOf: fileURL)
        guard let response = HTTPURLResponse(
            url: url, statusCode: fixture == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        else { throw URLError(.badServerResponse) }
        return (data, response)
    }

    /// Any recipe id gets the one recorded detail / payload; thumbnails are 404 (placeholder art).
    private static func fixture(for parts: [String], favoritesOnly: Bool) -> String? {
        guard parts.count >= 3, parts[0] == "api", parts[1] == "v1" else { return nil }
        let rest = Array(parts.dropFirst(2))
        switch (rest[0], rest.count) {
        case ("recipes", 1): return favoritesOnly ? "recipe_list_favorites" : "recipe_list"
        case ("recipes", 2): return "recipe_detail"
        case ("recipes", 3) where rest[2] == "camera-payload.json": return "camera_payload"
        case ("collections", 1): return "collection_list"
        case ("collections", 2): return "collection_detail"
        case ("camera", 2) where rest[1] == "client-config.json": return "camera_client_config"
        default: return nil
        }
    }
}

/// A path monitor that never reports a change (demo mode and tests).
struct IdlePathEvents: NetworkPathEvents {
    func pathChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
