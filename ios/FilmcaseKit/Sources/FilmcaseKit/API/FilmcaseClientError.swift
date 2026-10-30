import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FilmcaseClientError: Error, Sendable {
    /// 401, or no token is stored. The server is the right one; the token is wrong.
    case unauthorized
    /// 503: the server runs but `FILMCASE_API_TOKEN` is not set on it.
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

    /// Classify a thrown URLSession error: a pin mismatch (which must never fail
    /// over to another endpoint) or an ordinary transport failure.
    static func fromTransport(_ error: any Error, host: String) -> FilmcaseClientError {
        if let mismatch = error as? PinMismatchError {
            return .pinMismatch(host: mismatch.host)
        }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey]
        if let mismatch = underlying as? PinMismatchError {
            return .pinMismatch(host: mismatch.host)
        }
        return .transport(error)
    }
}

func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
