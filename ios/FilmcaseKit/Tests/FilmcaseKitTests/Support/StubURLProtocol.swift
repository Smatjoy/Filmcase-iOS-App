// A URLProtocol stub that is safe under Swift 6 and under parallel tests: each
// test registers its own fake host (a fresh UUID in the name) in a global,
// lock-protected registry, so tests never share state.

import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum StubReply: Sendable {
    case http(status: Int, body: Data, headers: [String: String] = [:])
    case failure(any Error)
    /// Never answers; ends only when the request is cancelled.
    case hang

    static func fixture(_ name: String, status: Int = 200) -> StubReply {
        .http(status: status, body: Fixture.data(name), headers: ["Content-Type": "application/json"])
    }

    static func transportError(_ code: URLError.Code = .cannotConnectToHost) -> StubReply {
        .failure(URLError(code))
    }
}

/// One fake host. Replies come from `handler`, which a test may replace mid-flight.
final class StubServer: Sendable {
    let host: String
    private let handler: Mutex<@Sendable (URLRequest) -> StubReply>
    private let recorded = Mutex<[URLRequest]>([])

    init(name: String, handler: @escaping @Sendable (URLRequest) -> StubReply = { _ in .transportError() }) {
        host = "\(name)-\(UUID().uuidString.lowercased()).test"
        self.handler = Mutex(handler)
        StubRegistry.register(self)
    }

    deinit { StubRegistry.unregister(host: host) }

    var baseURL: URL { URL(string: "https://\(host)")! }

    func setHandler(_ newHandler: @escaping @Sendable (URLRequest) -> StubReply) {
        handler.withLock { $0 = newHandler }
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    /// Requests that are not health probes (probes carry no Authorization header).
    var authenticatedRequests: [URLRequest] {
        requests.filter { $0.value(forHTTPHeaderField: "Authorization") != nil }
    }

    var probes: [URLRequest] {
        requests.filter { $0.value(forHTTPHeaderField: "Authorization") == nil }
    }

    fileprivate func reply(to request: URLRequest) -> StubReply {
        recorded.withLock { $0.append(request) }
        let current = handler.withLock { $0 }
        return current(request)
    }
}

enum StubRegistry {
    private static let servers = Mutex<[String: Weak]>([:])

    private struct Weak { weak var server: StubServer? }

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.host] = Weak(server: server) }
    }

    static func unregister(host: String) {
        servers.withLock { $0[host] = nil }
    }

    fileprivate static func server(for host: String) -> StubServer? {
        servers.withLock { $0[host]?.server }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = StubRegistry.server(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch server.reply(to: request) {
        case let .http(status, body, headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}
