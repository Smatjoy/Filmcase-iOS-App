// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import CryptoKit
import FilmcaseKit
import Foundation
import Security
import Synchronization

/// Why a cancelled server-trust challenge was cancelled, per task.
///
/// A task whose challenge is answered with `.cancelAuthenticationChallenge` fails
/// with a bare `URLError(.cancelled)`; URLSession offers no way to attach a custom
/// underlying error from the delegate. So the delegate records the reason here,
/// keyed by `URLSessionTask.taskIdentifier`, and `PinningTransport` re-throws it.
final class PinFailureLog: Sendable {
    private let entries = Mutex<[Int: any Error]>([:])

    func record(_ error: any Error, forTask identifier: Int) {
        entries.withLock { $0[identifier] = error }
    }

    /// Remove and return the entry for *identifier* (nil if the task was not rejected).
    func take(task identifier: Int) -> (any Error)? {
        entries.withLock { $0.removeValue(forKey: identifier) }
    }
}

/// Answers server-trust challenges with `TrustEvaluator` (see its doc comment for
/// the contract). It only translates between URLSession types and the evaluator's
/// three decisions; the decisions themselves live in FilmcaseKit.
final class PinningSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let evaluator: TrustEvaluator
    private let failures: PinFailureLog

    init(evaluator: TrustEvaluator, failures: PinFailureLog) {
        self.evaluator = evaluator
        self.failures = failures
        super.init()
    }

    // API: URLSessionTaskDelegate.urlSession(_:task:didReceive:) async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    // The task-level method is preferred over the session-level one for every challenge once implemented,
    // and it gives us the task, which the failure log is keyed by.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace // API: URLAuthenticationChallenge.protectionSpace
        // API: NSURLAuthenticationMethodServerTrust, URLProtectionSpace.authenticationMethod
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        let host = space.host // API: URLProtectionSpace.host
        guard let trust = space.serverTrust, // API: URLProtectionSpace.serverTrust
              let fingerprint = Self.leafFingerprintHex(of: trust)
        else {
            return (.cancelAuthenticationChallenge, nil)
        }
        do {
            switch try await evaluator.evaluate(host: host, presentedFingerprintSHA256Hex: fingerprint) {
            case .trusted:
                // API: URLCredential.init(trust: SecTrust)
                return (.useCredential, URLCredential(trust: trust))
            case .unpinned(let presented):
                failures.record(UnpinnedHostError(host: host, fingerprint: presented), forTask: task.taskIdentifier)
                return (.cancelAuthenticationChallenge, nil)
            case .mismatch:
                failures.record(PinMismatchError(host: host), forTask: task.taskIdentifier)
                return (.cancelAuthenticationChallenge, nil)
            }
        } catch {
            // The pin store itself failed (Keychain error): reject, surface it as the cause.
            failures.record(error, forTask: task.taskIdentifier)
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// Lowercase hex SHA-256 of the leaf certificate's DER bytes, or nil if there is no chain.
    static func leafFingerprintHex(of trust: SecTrust) -> String? {
        // API: SecTrustCopyCertificateChain(_ trust: SecTrust) -> CFArray?  (iOS 15+; leaf first)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        // API: SecCertificateCopyData(_ certificate: SecCertificate) -> CFData
        let der = SecCertificateCopyData(leaf) as Data
        // API: CryptoKit.SHA256.hash(data:) -> SHA256.Digest (a Sequence of UInt8)
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
