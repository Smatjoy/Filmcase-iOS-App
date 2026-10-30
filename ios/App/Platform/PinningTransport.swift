// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// FilmcaseClient and ServerEndpoints take a plain `URLSession` (a final class, so it
// cannot be wrapped), which gives the app no place to re-throw a recorded pin
// failure. The workaround: the session the client sees is configured with
// `PinningURLProtocol`, which forwards each request to the inner session owned by
// `PinningTransport` (the one with the pinning delegate) and delivers either the
// response or the recorded pin error back to the caller. Remove this indirection if
// FilmcaseClient ever takes a transport protocol instead of a URLSession.

import FilmcaseKit
import Foundation
import Synchronization

/// The inner, pinning URLSession plus the re-throw of recorded pin failures.
final class PinningTransport: Sendable {
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

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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

/// Forwards every `https` request of the sessions that list it in
/// `URLSessionConfiguration.protocolClasses` to the installed `PinningTransport`.
/// Never registered globally, so the inner session is not intercepted.
final class PinningURLProtocol: URLProtocol, @unchecked Sendable {
    private static let transport = Mutex<PinningTransport?>(nil)
    private let loading = Mutex<Task<Void, Never>?>(nil)

    static func install(_ transport: PinningTransport) {
        Self.transport.withLock { $0 = transport }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let transport = Self.transport.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let request = request
        let task = Task { [self] in
            do {
                let (data, response) = try await transport.data(for: request)
                // API: URLProtocolClient.urlProtocol(_:didReceive:cacheStoragePolicy:), .urlProtocol(_:didLoad:), .urlProtocolDidFinishLoading(_:)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                // API: URLProtocolClient.urlProtocol(_:didFailWithError:)
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        loading.withLock { $0 = task }
    }

    override func stopLoading() {
        loading.withLock { $0?.cancel() }
    }
}
