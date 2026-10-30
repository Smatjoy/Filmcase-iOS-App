import Foundation

/// Where the API bearer token lives. The app supplies a Keychain-backed adapter;
/// one token serves every endpoint.
public protocol TokenStore: Sendable {
    func token() async throws -> String?
    func save(token: String) async throws
    func deleteToken() async throws
}

public actor InMemoryTokenStore: TokenStore {
    private var stored: String?

    public init(token: String? = nil) {
        stored = token
    }

    public func token() -> String? { stored }
    public func save(token: String) { stored = token }
    public func deleteToken() { stored = nil }
}
