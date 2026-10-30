// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// The API bearer token in the Keychain. An actor so the blocking `SecItem*` calls
/// never run on the main actor.
actor KeychainTokenStore: TokenStore {
    private static let account = "api-token"
    private let keychain = GenericPasswordStore(service: "dev.filmcase.api-token")

    func token() throws -> String? {
        try keychain.read(account: Self.account).flatMap { String(data: $0, encoding: .utf8) }
    }

    func save(token: String) throws {
        try keychain.write(Data(token.utf8), account: Self.account)
    }

    func deleteToken() throws {
        try keychain.delete(account: Self.account)
    }
}
