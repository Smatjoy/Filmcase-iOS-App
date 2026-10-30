// The one network call FilmcaseClient and ServerEndpoints make. A protocol rather
// than URLSession itself, so the app can put certificate pinning in front of it and
// re-throw *why* a server-trust challenge was rejected: URLSession reports a
// cancelled challenge as a bare URLError(.cancelled).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    /// Perform *request* and return its body and response. A rejected certificate
    /// must throw (directly, or as a `URLError`'s `NSUnderlyingErrorKey`) a
    /// `PinMismatchError` or `UnpinnedHostError`, so it is reported instead of
    /// failing over (see `TrustEvaluator`).
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}
