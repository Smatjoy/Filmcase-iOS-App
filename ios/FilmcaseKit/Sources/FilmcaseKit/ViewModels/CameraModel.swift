// The Camera tab: connection pill and the C1-Cn slot grid.

import Foundation
import Observation

/// What `CameraModel` needs from the connection. `CameraConnection` conforms.
public protocol CameraConnectionControl: CameraOperationRunner {
    var states: AsyncStream<ConnectionState> { get }
    func connect() async
    func disconnect() async
    /// Whether a camera is plugged in right now, as far as the connection knows.
    var isDeviceAttached: Bool { get async }
}

extension CameraConnectionControl {
    /// For controls that cannot tell: the model then never reconnects after a loss by itself.
    public var isDeviceAttached: Bool { get async { false } }
}

extension CameraConnection: CameraConnectionControl {}

/// One cell of the slot grid.
public struct SlotItem: Equatable, Identifiable, Sendable {
    public let index: Int
    public let name: String
    public let filmSimName: String

    public var id: Int { index }
    /// "C3".
    public var title: String { "C\(index)" }
    public var displayName: String { name.isEmpty ? "Empty" : name }
    /// "C3, Kodak Portra 400, Classic Negative".
    public var accessibilityLabel: String {
        "\(title), \(name.isEmpty ? "empty" : name), \(filmSimName)"
    }

    public init(index: Int, name: String, filmSimName: String) {
        self.index = index
        self.name = name
        self.filmSimName = filmSimName
    }

    public init(_ state: SlotState) {
        self.init(index: state.index, name: state.name, filmSimName: state.filmSimName)
    }
}

/// The connection pill: what link is up (or none) and the words for it.
public struct ConnectionPill: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case none
        case usb
        /// Reserved for the Bluetooth transport.
        case ble
    }

    public let kind: Kind
    public let text: String
    public let isReady: Bool

    public init(for state: ConnectionState) {
        let text = UserMessages.text(for: state)
        switch state {
        case .ready:
            self.init(kind: .usb, text: "USB: \(text)", isReady: true)
        case .opening, .busy, .recovering:
            self.init(kind: .usb, text: text, isReady: false)
        case .idle, .awaitingAuthorization, .unauthorized, .searching, .lost:
            self.init(kind: .none, text: text, isReady: false)
        }
    }

    init(kind: Kind, text: String, isReady: Bool) {
        self.kind = kind
        self.text = text
        self.isReady = isReady
    }
}

extension LostReason {
    /// A loss that leaves the camera plugged in, so only asking again can bring it back.
    fileprivate var isWorthReconnecting: Bool {
        switch self {
        case .sessionClosed, .transportError: return true
        case .disconnected, .stalled, .recoveryFailed, .openFailed: return false
        }
    }
}

/// Why a `CameraModel` stopped connecting by itself. Only the person lifts it, by connecting.
public enum AutoConnectSuspension: Equatable, Sendable {
    /// Camera access was refused (or cancelled); asking again is the person's call.
    case authorizationDeclined
    /// The person disconnected.
    case userDisconnected
    /// Turned off when the model was made.
    case disabled
}

@MainActor
@Observable
public final class CameraModel {
    public enum SlotsState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var connectionState: ConnectionState = .idle
    public private(set) var slots: [SlotItem] = []
    public private(set) var slotsState: SlotsState = .idle
    public private(set) var errorMessage: String?
    /// Why `observe()` does not connect by itself; nil while it does.
    public private(set) var autoConnectSuspension: AutoConnectSuspension?

    @ObservationIgnored private let connection: any CameraConnectionControl
    @ObservationIgnored private let runtimeSource: any CameraRuntimeSource
    @ObservationIgnored private var slotsTask: Task<Void, Never>?
    @ObservationIgnored private var slotsGeneration = 0

    /// - Parameter autoConnect: Whether `observe()` connects by itself (see `observe()`).
    public init(connection: any CameraConnectionControl, runtime: any CameraRuntimeSource, autoConnect: Bool = true) {
        self.autoConnectSuspension = autoConnect ? nil : .disabled
        self.connection = connection
        self.runtimeSource = runtime
    }

    public var pill: ConnectionPill { ConnectionPill(for: connectionState) }

    public var isReady: Bool {
        if case .ready = connectionState { return true }
        return false
    }

    // --- intents ---

    /// Follow the connection until the calling task is cancelled (run it from `.task`).
    /// Slots are read whenever a camera becomes ready, and cleared when it goes.
    ///
    /// While the model is idle and auto-connect is not suspended, it connects by itself, so a
    /// camera that is plugged in needs no tap: the connection asks for access if needed, then
    /// waits for the camera and opens it. A camera that is unplugged and plugged in again is
    /// picked up by the connection's own event loop. When the session was closed under a camera
    /// that is still plugged in (`lost(.sessionClosed)`, `lost(.transportError)`), nothing
    /// announces it again, so the model reconnects once per loss (the allowance returns when a
    /// session becomes ready, so a camera that keeps failing is not retried forever).
    public func observe() async {
        var wasConnected = false
        var reconnectAllowed = true
        for await state in connection.states {
            connectionState = state
            if state == .unauthorized, autoConnectSuspension != .disabled {
                autoConnectSuspension = .authorizationDeclined
            }
            if state == .idle, autoConnectSuspension == nil {
                // Not awaited here: connecting can wait on the access prompt, and the states
                // it produces must keep flowing into this loop.
                let connection = self.connection
                Task { await connection.connect() }
            }
            if case .lost(let reason) = state, autoConnectSuspension == nil, reconnectAllowed,
               reason.isWorthReconnecting, await connection.isDeviceAttached,
               autoConnectSuspension == nil {
                reconnectAllowed = false
                let connection = self.connection
                Task { await connection.connect() }
            }
            if case .ready = state { reconnectAllowed = true }
            let connected: Bool
            switch state {
            case .ready, .busy, .recovering: connected = true
            default: connected = false
            }
            if case .ready = state, !wasConnected {
                refreshSlotsInBackground()
            } else if !connected, wasConnected || !slots.isEmpty {
                slotsGeneration += 1
                slotsTask?.cancel()
                slots = []
                slotsState = .idle
            }
            wasConnected = connected
        }
    }

    /// The person asked to connect (also lifts a suspension of auto-connect).
    public func connect() async {
        errorMessage = nil
        if autoConnectSuspension != .disabled { autoConnectSuspension = nil }
        await connection.connect()
    }

    /// The person asked to disconnect; auto-connect stays off until they connect again.
    public func disconnect() async {
        if autoConnectSuspension != .disabled { autoConnectSuspension = .userDisconnected }
        await connection.disconnect()
    }

    /// Read every custom slot's name and film simulation.
    public func refreshSlots() async {
        slotsGeneration += 1
        let token = slotsGeneration
        slotsState = .loading
        errorMessage = nil
        let runtime = await runtimeSource.currentRuntime()
        do {
            let states = try await connection.run("Read slots") { device in
                try await getCameraSlots(device, runtime: runtime)
            }
            guard token == slotsGeneration else { return }
            slots = states.map(SlotItem.init)
            slotsState = .loaded
        } catch is CancellationError {
            if token == slotsGeneration { slotsState = .idle }
        } catch {
            guard token == slotsGeneration else { return }
            let message = UserMessages.text(for: error)
            slotsState = .failed(message)
            errorMessage = message
        }
    }

    private func refreshSlotsInBackground() {
        slotsTask?.cancel()
        slotsTask = Task { [weak self] in await self?.refreshSlots() }
    }
}
