// The connection state machine as a pure function: (state, event) -> next state, or nil when
// the event is illegal in that state. CameraConnection applies it and does the side effects;
// keeping the table here makes every state/event pair testable without a transport.

import Foundation

/// Why a connection ended up in `lost`.
public enum LostReason: Equatable, Sendable {
    /// The camera was unplugged or switched off.
    case disconnected
    /// The platform closed the session.
    case sessionClosed
    /// An operation stalled, was retried after recovery, and stalled again.
    case stalled
    /// The session could not be reopened, or the slot cursor not restored, after a stall.
    case recoveryFailed(String)
    /// The session could not be opened in the first place.
    case openFailed(String)
    /// The platform reported a failure outside any call.
    case transportError(String)
}

public enum ConnectionState: Equatable, Sendable {
    case idle
    case awaitingAuthorization
    case unauthorized
    case searching
    case opening
    case ready(cameraName: String)
    case busy(cameraName: String, operation: String)
    /// A stalled operation is being recovered: session reopened, slot cursor restored, and
    /// the operation retried. Stays until the retry finishes.
    case recovering(cameraName: String, operation: String, attempt: Int)
    case lost(LostReason)
}

public enum ConnectionEvent: Equatable, Sendable {
    /// The person (or the app on launch) asked to connect.
    case connect
    case authorizationResult(granted: Bool)
    case deviceAdded
    case deviceRemoved
    case sessionOpened(cameraName: String)
    case sessionOpenFailed(String)
    case beginOperation(String)
    /// The operation finished, successfully or with its own error.
    case endOperation
    /// An operation exceeded its timeout.
    case stalled
    /// Reopening the session or restoring the slot cursor failed.
    case recoveryFailed(String)
    case sessionClosed
    case transportError(String)
    /// The person (or the app) is done with the camera.
    case disconnect
}

extension ConnectionState {
    /// The state after *event*, or nil if the event is illegal here (the connection ignores it).
    public func applying(_ event: ConnectionEvent) -> ConnectionState? {
        switch (self, event) {
        case (_, .disconnect):
            return .idle

        case (.idle, .connect), (.unauthorized, .connect), (.lost, .connect):
            return .awaitingAuthorization

        case (.awaitingAuthorization, .authorizationResult(let granted)):
            return granted ? .searching : .unauthorized

        case (.searching, .deviceAdded), (.lost, .deviceAdded):
            return .opening

        case (.opening, .sessionOpened(let name)):
            return .ready(cameraName: name)
        case (.opening, .sessionOpenFailed(let message)):
            return .lost(.openFailed(message))

        case (.ready(let name), .beginOperation(let operation)):
            return .busy(cameraName: name, operation: operation)
        case (.busy(let name, _), .endOperation), (.recovering(let name, _, _), .endOperation):
            return .ready(cameraName: name)

        case (.busy(let name, let operation), .stalled):
            return .recovering(cameraName: name, operation: operation, attempt: 1)
        case (.recovering, .stalled):
            return .lost(.stalled)
        case (.recovering, .recoveryFailed(let message)):
            return .lost(.recoveryFailed(message))

        case (.opening, .deviceRemoved), (.ready, .deviceRemoved), (.busy, .deviceRemoved),
             (.recovering, .deviceRemoved):
            return .lost(.disconnected)

        case (.opening, .sessionClosed), (.ready, .sessionClosed), (.busy, .sessionClosed),
             (.recovering, .sessionClosed):
            return .lost(.sessionClosed)

        case (.searching, .transportError(let m)), (.opening, .transportError(let m)),
             (.ready, .transportError(let m)), (.busy, .transportError(let m)),
             (.recovering, .transportError(let m)):
            return .lost(.transportError(m))

        default:
            return nil
        }
    }
}
