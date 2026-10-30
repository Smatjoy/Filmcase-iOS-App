// Pure decision logic for trust-on-first-use certificate pinning. No Security
// framework here: the Apple adapter owns the SecTrust plumbing.

import Foundation
import Synchronization

/// Persistent fingerprint per host (a Keychain adapter in the app).
public protocol PinStore: Sendable {
    func fingerprint(for host: String) throws -> String?
    func setFingerprint(_ fingerprint: String, for host: String) throws
    func removeFingerprint(for host: String) throws
}

public final class InMemoryPinStore: PinStore {
    private let pins: Mutex<[String: String]>

    public init(pins: [String: String] = [:]) {
        self.pins = Mutex(pins)
    }

    public func fingerprint(for host: String) -> String? {
        pins.withLock { $0[host] }
    }

    public func setFingerprint(_ fingerprint: String, for host: String) {
        pins.withLock { $0[host] = fingerprint }
    }

    public func removeFingerprint(for host: String) {
        pins.withLock { $0[host] = nil }
    }
}

public enum TrustDecision: Sendable, Equatable {
    /// No pin existed; the presented fingerprint was stored. Accept the connection.
    case trustOnFirstUse(fingerprint: String)
    /// Matches the stored pin. Accept.
    case trusted
    /// Differs from the stored pin. Reject, and tell the user (`FilmcaseClientError.pinMismatch`).
    case mismatch(expected: String, presented: String)
}

/// Decides whether a presented server certificate is acceptable for a host.
///
/// Contract for the Apple adapter (URLSession challenge delegate): on a
/// `NSURLAuthenticationMethodServerTrust` challenge, take the leaf certificate's
/// DER bytes, compute SHA-256 with CryptoKit, hex-encode it, and call
/// `evaluate(host:presentedFingerprintSHA256Hex:)` with the challenge's
/// `protectionSpace.host`. Accept the credential for `.trustOnFirstUse` and
/// `.trusted`; cancel the challenge for `.mismatch`, failing the request with a
/// `URLError` whose underlying error is `PinMismatchError`. System trust
/// evaluation is not consulted: the self-hosted server may use a private CA or a
/// self-signed certificate, and the pin is the trust anchor.
///
/// Pins are per host, because the LAN and Tailscale names may present different
/// certificates. Hosts and fingerprints are compared case-insensitively, and
/// fingerprints ignore `:` and whitespace separators. An actor, so two
/// simultaneous first connections to one host cannot both win.
public actor TrustEvaluator {
    private let store: any PinStore

    public init(store: any PinStore) {
        self.store = store
    }

    public func evaluate(host: String, presentedFingerprintSHA256Hex: String) throws -> TrustDecision {
        let host = Self.normalizedHost(host)
        let presented = Self.normalizedFingerprint(presentedFingerprintSHA256Hex)
        guard let expected = try store.fingerprint(for: host) else {
            try store.setFingerprint(presented, for: host)
            return .trustOnFirstUse(fingerprint: presented)
        }
        if expected == presented { return .trusted }
        return .mismatch(expected: expected, presented: presented)
    }

    /// Forget the pin for *host*, so the next connection is trust-on-first-use
    /// again. Only for an explicit user action after a legitimate certificate change.
    public func forget(host: String) throws {
        try store.removeFingerprint(for: Self.normalizedHost(host))
    }

    static func normalizedHost(_ host: String) -> String {
        host.lowercased()
    }

    static func normalizedFingerprint(_ hex: String) -> String {
        String(hex.lowercased().filter { $0 != ":" && !$0.isWhitespace })
    }
}

/// Raised (typically as the underlying error of a `URLError`) by the Apple
/// adapter's challenge delegate when `TrustEvaluator` answered `.mismatch`, so
/// `FilmcaseClient` can report `.pinMismatch(host)` instead of a generic
/// transport error.
public struct PinMismatchError: Error, Sendable, Equatable {
    public let host: String

    public init(host: String) {
        self.host = host
    }
}
