// Minimal injected time source. Shadows Swift.Clock inside this module on purpose:
// everything in FilmcaseKit that needs time takes one of these, so tests can
// control it (see TestClock in the test target).

import Foundation

public protocol Clock: Sendable {
    /// The current wall-clock time.
    var now: Date { get }

    /// Suspend for *duration*. Throws `CancellationError` if the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// The real clock, backed by `Task.sleep`.
public struct SystemClock: Clock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
