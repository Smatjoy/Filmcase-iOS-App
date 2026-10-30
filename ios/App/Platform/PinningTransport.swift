// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// The `HTTPTransport` FilmcaseClient and ServerEndpoints use in the app. URLSession
// reports a cancelled server-trust challenge as a bare URLError(.cancelled), so the
// pinning delegate records why it cancelled, per task, and this transport re-throws
// that reason as the FilmcaseKit contract expects.

import FilmcaseKit
import Foundation
import Synchronization

/// A pinning URLSession plus the re-throw of recorded pin failures.
final class PinningTransport: HTTPTransport {
    private let session: URLSession
    private let failures: PinFailureLog
    // Held only so the session's delegate stays alive and is documented here:
    // URLSession retains its delegate until invalidated.
    private let delegate: PinningSessionDelegate

    init(evaluator: TrustEvaluator) {
        let failures = PinFailureLog()
        let delegate = PinningSessionDelegate(evaluator: evaluator, failures: failures)
        let configuration = URLSessionConfiguration.ephemeral // API: URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        // API: URLSession.init(configuration:delegate:delegateQueue:)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.failures = failures
        self.delegate = delegate
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), any Error>) in
                let failures = failures
                // API: URLSession.dataTask(with: URLRequest, completionHandler:) -> URLSessionDataTask
                let task = session.dataTask(with: request) { data, response, error in
                    let identifier = handle.task.withLock { $0?.taskIdentifier ?? -1 }
                    let recorded = failures.take(task: identifier)
                    if let error {
                        continuation.resume(throwing: Self.surfaced(error, recorded: recorded))
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                handle.task.withLock { $0 = task }
                task.resume() // API: URLSessionTask.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            handle.task.withLock { $0?.cancel() } // API: URLSessionTask.cancel()
        }
    }

    /// The error the caller sees: the cancelled challenge's recorded reason as the
    /// underlying error of a `URLError`, as the FilmcaseKit contract specifies.
    private static func surfaced(_ error: any Error, recorded: (any Error)?) -> any Error {
        guard let recorded else { return error }
        // API: URLError.init(_:userInfo:), URLError.Code.serverCertificateUntrusted, NSUnderlyingErrorKey
        return URLError(.serverCertificateUntrusted, userInfo: [NSUnderlyingErrorKey: recorded])
    }
}

private final class TaskHandle: Sendable {
    let task = Mutex<URLSessionTask?>(nil)
}
