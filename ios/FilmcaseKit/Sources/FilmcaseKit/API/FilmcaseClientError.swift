import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FilmcaseClientError: Error, Sendable {
    /// 401: the server requires a token and the stored one is missing or wrong.
    case unauthorized
    /// 503 from a server older than the optional token, where `FILMCASE_API_TOKEN` is unset.
    case serverNotConfigured
    /// 404.
    case notFound
    /// 400, with the server's message.
    case badRequest(String)
    /// Any other non-2xx status.
    case unexpectedStatus(Int)
    /// The connection failed (not a pin problem).
    case transport(any Error)
    /// A 2xx body did not match the DTO; the string describes where.
    case decoding(String)
    /// The server presented a certificate that differs from the pinned one.
    case pinMismatch(host: String)
    /// The host has no pin yet; the user must approve *fingerprint* first.
    case unpinnedHost(host: String, fingerprint: String)
    /// No configured endpoint answered.
    case noReachableServer
}

extension FilmcaseClientError {
    /// The error for a non-2xx *status*, or nil for a success.
    static func forStatus(_ status: Int, body: Data) -> FilmcaseClientError? {
        switch status {
        case 200..<300:
            return nil
        case 400:
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: body))?.error
            return .badRequest(message ?? "Bad request.")
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 503:
            return .serverNotConfigured
        default:
            return .unexpectedStatus(status)
        }
    }

    /// Classify a thrown URLSession error: a pin problem (which must never fail
    /// over to another endpoint) or an ordinary transport failure.
    static func fromTransport(_ error: any Error, host: String) -> FilmcaseClientError {
        for candidate in [error, (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error] {
            if let mismatch = candidate as? PinMismatchError {
                return .pinMismatch(host: mismatch.host)
            }
            if let unpinned = candidate as? UnpinnedHostError {
                return .unpinnedHost(host: unpinned.host, fingerprint: unpinned.fingerprint)
            }
        }
        return .transport(error)
    }

    /// True for the errors that mean "this server's certificate is not trusted",
    /// which surface to the user instead of failing over.
    var isPinProblem: Bool {
        switch self {
        case .pinMismatch, .unpinnedHost: true
        default: false
        }
    }
}

func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
