// Shared fixtures for the view-model tests: a client over a scripted transport, recipe
// page JSON, and a transport that holds responses until the test releases them.

import Foundation
import Synchronization
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

// --- JSON builders ---

func summaryJSON(id: Int) -> [String: Any] {
    [
        "id": id, "name": "Recipe \(id)", "film_simulation": "Provia", "dynamic_range": "DR100",
        "grain_roughness": "Off", "color_chrome_effect": "Off", "white_balance": "Auto",
        "image_count": 0, "is_favorite": false, "version": NSNull(), "cover_thumbnail_url": NSNull(),
    ]
}

func facetJSON(label: String, values: [String]) -> [String: Any] {
    [
        "label": label,
        "options": values.map { ["value": $0, "count": 1, "available": true, "selected": false] as [String: Any] },
        "selected": [String](),
    ]
}

/// A `GET /api/v1/recipes/` body.
func pageBody(
    ids: [Int], count: Int? = nil, hasNext: Bool = false, facets: [String: Any] = [:]
) -> Data {
    let body: [String: Any] = [
        "count": count ?? ids.count,
        "next": hasNext ? "/api/v1/recipes/?page=2" : NSNull(),
        "previous": NSNull(),
        "results": ids.map(summaryJSON),
        "facets": facets,
    ]
    return try! JSONSerialization.data(withJSONObject: body)
}

func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func jsonObject(fixture name: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Fixture.data(name)) as! [String: Any]
}

func reply(_ data: Data, status: Int = 200) -> StubReply {
    .http(status: status, body: data, headers: ["Content-Type": "application/json"])
}

// --- requests ---

extension URLRequest {
    func queryValue(_ name: String) -> String? {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == name }?.value
    }

    func queryValues(_ name: String) -> [String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [] }
        return items.filter { $0.name == name }.compactMap(\.value)
    }

    var isAuthenticated: Bool { value(forHTTPHeaderField: "Authorization") != nil }
}

// --- a transport the test controls ---

/// Answers from a script, and can hold an answer back until `release`. Requests are held
/// per `name_search` value, so a test can answer an older search after a newer one.
final class GatedTransport: HTTPTransport, Sendable {
    private struct Waiter {
        let key: String
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var gated: Set<String> = []
        var waiters: [Int: Waiter] = [:]
        var cancelledEarly: Set<Int> = []
        var nextID = 0
        var requests: [URLRequest] = []
        var cancellations = 0
    }

    private let state = Mutex(State())
    private let script: Mutex<@Sendable (URLRequest) -> StubReply>
    /// Whether a held request ends when its task is cancelled (like URLSession) or keeps
    /// waiting for `release` (a transport that ignores cancellation).
    private let honorsCancellation: Bool

    init(honorsCancellation: Bool = true, script: @escaping @Sendable (URLRequest) -> StubReply) {
        self.honorsCancellation = honorsCancellation
        self.script = Mutex(script)
    }

    func setScript(_ newScript: @escaping @Sendable (URLRequest) -> StubReply) {
        script.withLock { $0 = newScript }
    }

    /// Hold authenticated requests whose `name_search` is *search* ("" for none).
    func gate(search: String) { _ = state.withLock { $0.gated.insert(search) } }

    /// Stop holding *search*, and answer the requests already held.
    func release(search: String) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.gated.remove(search)
            let ids = state.waiters.filter { $0.value.key == search }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready { continuation.resume() }
    }

    var requests: [URLRequest] { state.withLock { $0.requests } }
    var authenticatedRequests: [URLRequest] { requests.filter(\.isAuthenticated) }
    var cancellations: Int { state.withLock { $0.cancellations } }
    func held(search: String) -> Int { state.withLock { $0.waiters.values.filter { $0.key == search }.count } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        state.withLock { $0.requests.append(request) }
        if request.isAuthenticated { try await hold(request.queryValue("name_search") ?? "") }
        let answer = script.withLock { $0 }(request)
        let url = request.url!
        switch answer {
        case let .http(status, body, headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        case let .failure(error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(86_400))
            throw URLError(.timedOut)
        }
    }

    private func hold(_ key: String) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        let honors = honorsCancellation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case go, cancel, wait }
                let action = state.withLock { state -> Action in
                    if state.cancelledEarly.remove(id) != nil { return .cancel }
                    if !state.gated.contains(key) { return .go }
                    state.waiters[id] = Waiter(key: key, continuation: continuation)
                    return .wait
                }
                switch action {
                case .go: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                state.cancellations += 1
                guard honors else { return nil }
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

// --- a client over any transport ---

/// A one-server client. `endpointClock` is separate from `clock` so the probe timeout's sleep
/// does not show up in the sleeps a test counts on the model's clock.
struct ModelRig {
    let server = URL(string: "https://model.test")!
    let transport: GatedTransport
    let clock = TestClock()
    let endpoints: ServerEndpoints
    let client: FilmcaseClient
    let tokenStore: InMemoryTokenStore

    init(honorsCancellation: Bool = true, token: String? = "tok", script: @escaping @Sendable (URLRequest) -> StubReply) {
        transport = GatedTransport(honorsCancellation: honorsCancellation, script: script)
        endpoints = ServerEndpoints(endpoints: [server], transport: transport, clock: TestClock())
        tokenStore = InMemoryTokenStore(token: token)
        client = FilmcaseClient(endpoints: endpoints, tokenStore: tokenStore, transport: transport)
    }
}

/// A recipe list that answers every search with *ids* for that search.
func searchScript(_ pages: @escaping @Sendable (URLRequest) -> Data) -> @Sendable (URLRequest) -> StubReply {
    { request in request.isAuthenticated ? reply(pages(request)) : reply(pageBody(ids: [1])) }
}

// --- camera source ---

/// A camera that can be plugged in and out from a test.
final class MutableCameraSource: ConnectedCameraSource {
    private let current = Mutex<ConnectedCamera?>(nil)

    init(_ camera: ConnectedCamera? = nil) { current.withLock { $0 = camera } }

    func set(_ camera: ConnectedCamera?) { current.withLock { $0 = camera } }
    func connectedCamera() async -> ConnectedCamera? { current.withLock { $0 } }
}

// --- waiting from the main actor ---

/// Poll until *condition* holds. Bounded (about 5 s) so a bug fails the test instead of hanging it.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<5_000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
