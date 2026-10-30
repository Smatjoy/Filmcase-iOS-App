// The camera connection state machine and its recovery policy.
//
// Recovery follows ADR 016 ("The browser needs a recovery mechanism"), adapted to iOS: a
// camera sometimes accepts a request and never answers it. When an operation outlives its
// timeout, the session is closed and reopened, the slot cursor (0xD18C, connection state that
// decides which slot every later write lands in) is restored to the last value written, and
// the operation is retried once. A second stall ends in `lost`. There is no Device Reset
// escalation: ImageCaptureCore owns the USB device, so closing the session is the strongest
// reset available.
//
// Operations passed to `run` must be cancellable, because the timeout race cancels them. The
// ImageCaptureCore adapter bridges its callbacks with `withTaskCancellationHandler`.

import Foundation
import Synchronization

/// Why `run` refused to start an operation.
public enum ConnectionError: Error, Equatable, Sendable {
    /// Another operation is running (or being recovered). Operations are exclusive.
    case busy
    /// The connection is not `ready`.
    case notReady(ConnectionState)
}

/// Runs operations against a connected camera. `CameraConnection` is the production
/// implementation; the workflows depend on this so they can be driven by anything.
public protocol CameraOperationRunner: Sendable {
    /// The model of the connected camera, or nil when not connected.
    var cameraName: String? { get async }

    /// Run *operation* exclusively against the camera, with timeout and recovery.
    /// The operation may run twice (once more after a recovery), so it must be safe to repeat.
    func run<T: Sendable>(
        _ name: String, _ operation: @escaping @Sendable (any PTPDevice) async throws -> T
    ) async throws -> T
}

public actor CameraConnection: CameraOperationRunner {
    public private(set) var current: ConnectionState = .idle

    /// Every state change, starting with the current state. Each access is a new subscription.
    public nonisolated var states: AsyncStream<ConnectionState> { broadcaster.subscribe() }

    /// Every state entered since creation, in order (for tests).
    private(set) var history: [ConnectionState] = [.idle]

    private let transport: any CameraTransport
    private let clock: any FilmcaseClock
    private let operationTimeout: Duration
    private let cursorCode: UInt16
    private let broadcaster = StateBroadcaster()
    private let cursor = CursorTracker()
    private var device: (any PTPDevice)?
    private var eventLoop: Task<Void, Never>?
    /// The camera the transport last reported attached. Tracked from events for the
    /// connection's whole lifetime, because the event stream is single-consumer and reports a
    /// camera only when it arrives: a later `connect()` must not wait for a re-announcement.
    private var attachedCameraName: String?
    private var abort: AbortSignal?

    /// - Parameters:
    ///   - config: Supplies the slot cursor property code (served, never hard-coded).
    ///   - operationTimeout: How long an operation may run before it counts as stalled.
    public init(
        transport: any CameraTransport,
        config: ClientConfig,
        clock: any FilmcaseClock = SystemClock(),
        operationTimeout: Duration = .seconds(30)
    ) {
        self.transport = transport
        self.clock = clock
        self.operationTimeout = operationTimeout
        self.cursorCode = UInt16(truncatingIfNeeded: config.encodings.propSlotCursor)
    }

    deinit {
        eventLoop?.cancel()
    }

    /// Whether the transport last reported a camera attached (whatever the connection state).
    public var isDeviceAttached: Bool { attachedCameraName != nil }

    public var cameraName: String? {
        switch current {
        case .ready(let name), .busy(let name, _), .recovering(let name, _, _): return name
        default: return nil
        }
    }

    // --- lifecycle ---

    /// Ask for access if needed, then wait for a camera and open a session. Progress is
    /// reported through `states`.
    public func connect() async {
        guard apply(.connect) else { return }
        let granted: Bool
        switch await transport.authorizationStatus {
        case .authorized: granted = true
        case .denied: granted = false
        case .notDetermined: granted = await transport.requestAuthorization()
        }
        guard current == .awaitingAuthorization else { return }
        apply(.authorizationResult(granted: granted))
        guard granted else { return }
        startEventLoop()
        // No suspension since `.searching`, so this cannot race the event loop.
        if attachedCameraName != nil, apply(.deviceAdded) { await openSession() }
    }

    /// Close the session and go idle. The event loop keeps running (it is the only consumer
    /// of the transport's events), so device presence stays known for the next `connect()`.
    public func disconnect() async {
        abort?.fire()
        apply(.disconnect)
        device = nil
        await transport.closeSession()
    }

    // --- operations ---

    public func run<T: Sendable>(
        _ name: String, _ operation: @escaping @Sendable (any PTPDevice) async throws -> T
    ) async throws -> T {
        switch current {
        case .ready: break
        case .busy, .recovering: throw ConnectionError.busy
        default: throw ConnectionError.notReady(current)
        }
        guard let device else { throw ConnectionError.notReady(current) }

        let signal = AbortSignal()
        abort = signal
        defer { abort = nil }
        apply(.beginOperation(name))

        switch await attempt(on: device, signal, operation) {
        case .value(let value):
            apply(.endOperation)
            return value
        case .failed(let error):
            apply(.endOperation)
            throw error
        case .cancelled:
            apply(.endOperation)
            throw CancellationError()
        case .aborted:
            throw abortError()
        case .timedOut:
            break
        }

        // The operation stalled: reopen, restore the cursor, retry once.
        guard apply(.stalled) else { throw lostError() }
        let transport = self.transport
        let tracker = self.cursor
        let cursorCode = self.cursorCode
        let reopened: Outcome<any PTPDevice> = await race(signal) {
            await transport.closeSession()
            let fresh = try await transport.openSession()
            if let slot = tracker.last {
                let rc = try await fresh.setUInt16(cursorCode, slot)
                if rc != 0 {
                    throw CameraConnectionError(
                        "Camera refused to restore slot cursor to \(slot) (rc=\(formatRc(rc)))")
                }
            }
            return fresh
        }
        let fresh: any PTPDevice
        switch reopened {
        case .value(let value):
            fresh = value
        case .aborted:
            throw abortError()
        case .cancelled:
            apply(.endOperation)
            throw CancellationError()
        case .timedOut, .failed:
            var message = "reopening the session timed out"
            if case .failed(let error) = reopened { message = String(describing: error) }
            apply(.recoveryFailed(message))
            await wentLost()
            throw CameraConnectionError("Camera did not recover from a stalled operation: \(message)")
        }
        self.device = fresh

        switch await attempt(on: fresh, signal, operation) {
        case .value(let value):
            apply(.endOperation)
            return value
        case .failed(let error):
            apply(.endOperation)
            throw error
        case .cancelled:
            apply(.endOperation)
            throw CancellationError()
        case .aborted:
            throw abortError()
        case .timedOut:
            apply(.stalled)
            await wentLost()
            throw CameraConnectionError("Camera stalled again after the session was reopened")
        }
    }

    // --- internals ---

    /// What a raced piece of work came to.
    private enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case failed(any Error)
        case timedOut
        /// The connection was lost while the work was running.
        case aborted
        case cancelled
    }

    private func attempt<T: Sendable>(
        on device: any PTPDevice, _ signal: AbortSignal,
        _ operation: @escaping @Sendable (any PTPDevice) async throws -> T
    ) async -> Outcome<T> {
        let tracked = CursorTrackingDevice(base: device, cursorCode: cursorCode, tracker: cursor)
        return await race(signal) { try await operation(tracked) }
    }

    /// Run *work* against the timeout and the abort signal; the first to finish wins and the
    /// others are cancelled.
    private func race<T: Sendable>(
        _ signal: AbortSignal, _ work: @escaping @Sendable () async throws -> T
    ) async -> Outcome<T> {
        let clock = self.clock
        let timeout = self.operationTimeout
        return await withTaskGroup(of: Outcome<T>.self) { group in
            group.addTask {
                do { return .value(try await work()) } catch { return .failed(error) }
            }
            group.addTask {
                do { try await clock.sleep(for: timeout); return .timedOut } catch { return .cancelled }
            }
            group.addTask {
                await signal.wait()
                return .aborted
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }
    }

    /// The abort child also finishes when the caller's task is cancelled; only a lost
    /// connection is reported as lost.
    private func abortError() -> any Error {
        if case .lost = current { return lostError() }
        apply(.endOperation)
        return CancellationError()
    }

    private func lostError() -> CameraConnectionError {
        if case .lost(let reason) = current {
            return CameraConnectionError("Camera connection lost (\(reason))")
        }
        return CameraConnectionError("Camera connection lost")
    }

    /// Apply *event* to the state machine. Illegal events are ignored and reported as false.
    @discardableResult
    private func apply(_ event: ConnectionEvent) -> Bool {
        guard let next = current.applying(event) else { return false }
        current = next
        history.append(next)
        broadcaster.send(next)
        return true
    }

    /// Side effects of entering `lost`: abandon any running operation and release the session.
    private func wentLost() async {
        abort?.fire()
        device = nil
        await transport.closeSession()
    }

    private func startEventLoop() {
        guard eventLoop == nil else { return }
        let events = transport.events
        eventLoop = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .deviceAdded(let name):
            attachedCameraName = name
            guard apply(.deviceAdded) else { return }
            await openSession()
        case .deviceRemoved:
            attachedCameraName = nil
            if apply(.deviceRemoved) { await wentLost() }
        case .sessionClosed:
            if apply(.sessionClosed) { await wentLost() }
        case .error(let message):
            if apply(.transportError(message)) { await wentLost() }
        }
    }

    private func openSession() async {
        do {
            let opened = try await transport.openSession()
            guard current == .opening else {
                await transport.closeSession()
                return
            }
            device = opened
            apply(.sessionOpened(cameraName: opened.cameraName))
        } catch {
            guard apply(.sessionOpenFailed(String(describing: error))) else { return }
            await wentLost()
        }
    }
}

/// Broadcasts state changes to any number of subscribers, each starting from the latest state.
final class StateBroadcaster: Sendable {
    private struct Box {
        var latest: ConnectionState = .idle
        var subscribers: [Int: AsyncStream<ConnectionState>.Continuation] = [:]
        var nextID = 0
    }

    private let box = Mutex(Box())

    func subscribe() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = box.withLock { box -> Int in
                box.nextID += 1
                box.subscribers[box.nextID] = continuation
                continuation.yield(box.latest)
                return box.nextID
            }
            continuation.onTermination = { [weak self] _ in
                self?.box.withLock { $0.subscribers[id] = nil }
            }
        }
    }

    func send(_ state: ConnectionState) {
        box.withLock { box in
            box.latest = state
            for continuation in box.subscribers.values { continuation.yield(state) }
        }
    }
}

/// The last slot cursor value the camera accepted. Connection state on the camera, so it
/// has to be put back after a reopened session.
final class CursorTracker: Sendable {
    private let value = Mutex<Int?>(nil)

    var last: Int? { value.withLock { $0 } }

    func record(_ slot: Int) { value.withLock { $0 = slot } }
}

/// Passes calls through and remembers each cursor write the camera accepted.
struct CursorTrackingDevice: PTPDevice {
    let base: any PTPDevice
    let cursorCode: UInt16
    let tracker: CursorTracker

    var cameraName: String { base.cameraName }

    func getInt(_ code: UInt16) async throws -> Int { try await base.getInt(code) }
    func getString(_ code: UInt16) async throws -> String { try await base.getString(code) }
    func setInt(_ code: UInt16, _ value: Int) async throws -> Int { try await base.setInt(code, value) }
    func setString(_ code: UInt16, _ value: String) async throws -> Int { try await base.setString(code, value) }

    func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int {
        let rc = try await base.setUInt16(code, value)
        if code == cursorCode && rc == 0 { tracker.record(value) }
        return rc
    }
}

/// One-shot signal that wakes every waiter, used to abandon an operation when the camera goes.
final class AbortSignal: Sendable {
    private struct State {
        var fired = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var cancelledEarly: Set<Int> = []
    }

    private let state = Mutex(State())

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Returns when fired, or when the waiting task is cancelled.
    func wait() async {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.fired || state.cancelledEarly.remove(id) != nil { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
                state.cancelledEarly.insert(id)
                return nil
            }
            waiter?.resume()
        }
    }
}
