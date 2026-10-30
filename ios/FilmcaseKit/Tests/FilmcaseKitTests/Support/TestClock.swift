import Foundation
import Synchronization
@testable import FilmcaseKit

/// A clock that only moves when the test says so. `sleep` suspends until
/// `advance(by:)` passes its deadline, and records every requested duration.
final class TestClock: FilmcaseClock {
    private struct Waiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var elapsed: Duration = .zero
        var nextID = 0
        var waiters: [Int: Waiter] = [:]
        var cancelledEarly: Set<Int> = []
        var sleeps: [Duration] = []
    }

    private let state = Mutex(State())
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        let elapsed = state.withLock { $0.elapsed }
        let parts = elapsed.components
        return epoch.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
    }

    /// Every duration passed to `sleep`, in call order.
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func sleep(for duration: Duration) async throws {
        // The deadline is fixed when the sleep is recorded, not when the waiter
        // registers: a test that sees the sleep (waitForSleeps) and advances before
        // registration must still wake it.
        let (id, deadline) = state.withLock { state -> (Int, Duration) in
            state.nextID += 1
            state.sleeps.append(duration)
            return (state.nextID, state.elapsed + duration)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Registration { case cancelled, alreadyDue, waiting }
                let registration = state.withLock { state -> Registration in
                    if state.cancelledEarly.remove(id) != nil { return .cancelled }
                    if deadline <= state.elapsed { return .alreadyDue }
                    state.waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return .waiting
                }
                switch registration {
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .alreadyDue: continuation.resume()
                case .waiting: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Waiter] in
            state.elapsed += duration
            let ids = state.waiters.filter { $0.value.deadline <= state.elapsed }.map(\.key)
            return ids.compactMap { state.waiters.removeValue(forKey: $0) }
        }
        for waiter in due { waiter.continuation.resume() }
    }

    /// Suspend until at least *count* sleeps have been requested (bounded, so a bug fails instead of hanging).
    func waitForSleeps(_ count: Int) async {
        for _ in 0..<100_000 where sleeps.count < count {
            await Task.yield()
        }
    }
}
