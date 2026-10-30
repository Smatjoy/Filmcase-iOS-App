// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation

/// One pinned fingerprint per host (account = host). `TrustEvaluator` normalises
/// hosts before calling, so no normalisation here. The calls are synchronous and
/// fast (single-item lookups), as the `PinStore` protocol requires.
struct KeychainPinStore: PinStore {
    private let keychain = GenericPasswordStore(service: "dev.filmcase.cert-pins")

    func fingerprint(for host: String) throws -> String? {
        try keychain.read(account: host).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setFingerprint(_ fingerprint: String, for host: String) throws {
        try keychain.write(Data(fingerprint.utf8), account: host)
    }

    func removeFingerprint(for host: String) throws {
        try keychain.delete(account: host)
    }
}
