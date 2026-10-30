// Every (state, event) pair of the connection state machine: the legal ones from an explicit
// table, and every other pair must be illegal (nil).

import Testing
@testable import FilmcaseKit

private let camera = "X-T50"

private let allStates: [ConnectionState] = [
    .idle, .awaitingAuthorization, .unauthorized, .searching, .opening,
    .ready(cameraName: camera),
    .busy(cameraName: camera, operation: "push"),
    .recovering(cameraName: camera, operation: "push", attempt: 1),
    .lost(.disconnected),
]

private let allEvents: [ConnectionEvent] = [
    .connect, .authorizationResult(granted: true), .authorizationResult(granted: false),
    .deviceAdded, .deviceRemoved, .sessionOpened(cameraName: camera), .sessionOpenFailed("boom"),
    .beginOperation("push"), .endOperation, .stalled, .recoveryFailed("nope"),
    .sessionClosed, .transportError("usb"), .disconnect,
]

private let ready = ConnectionState.ready(cameraName: camera)
private let busy = ConnectionState.busy(cameraName: camera, operation: "push")
private let recovering = ConnectionState.recovering(cameraName: camera, operation: "push", attempt: 1)

/// (from, event, to) for every legal transition except `disconnect`, which is legal everywhere.
private let legal: [(ConnectionState, ConnectionEvent, ConnectionState)] = [
    (.idle, .connect, .awaitingAuthorization),
    (.unauthorized, .connect, .awaitingAuthorization),
    (.lost(.disconnected), .connect, .awaitingAuthorization),
    (.awaitingAuthorization, .authorizationResult(granted: true), .searching),
    (.awaitingAuthorization, .authorizationResult(granted: false), .unauthorized),
    (.searching, .deviceAdded, .opening),
    (.lost(.disconnected), .deviceAdded, .opening),
    (.opening, .sessionOpened(cameraName: camera), ready),
    (.opening, .sessionOpenFailed("boom"), .lost(.openFailed("boom"))),
    (ready, .beginOperation("push"), busy),
    (busy, .endOperation, ready),
    (recovering, .endOperation, ready),
    (busy, .stalled, recovering),
    (recovering, .stalled, .lost(.stalled)),
    (recovering, .recoveryFailed("nope"), .lost(.recoveryFailed("nope"))),
    (.opening, .deviceRemoved, .lost(.disconnected)),
    (ready, .deviceRemoved, .lost(.disconnected)),
    (busy, .deviceRemoved, .lost(.disconnected)),
    (recovering, .deviceRemoved, .lost(.disconnected)),
    (.opening, .sessionClosed, .lost(.sessionClosed)),
    (ready, .sessionClosed, .lost(.sessionClosed)),
    (busy, .sessionClosed, .lost(.sessionClosed)),
    (recovering, .sessionClosed, .lost(.sessionClosed)),
    (.searching, .transportError("usb"), .lost(.transportError("usb"))),
    (.opening, .transportError("usb"), .lost(.transportError("usb"))),
    (ready, .transportError("usb"), .lost(.transportError("usb"))),
    (busy, .transportError("usb"), .lost(.transportError("usb"))),
    (recovering, .transportError("usb"), .lost(.transportError("usb"))),
]

@Suite("ConnectionState transitions")
struct ConnectionStateTests {
    @Test("every state/event pair is legal exactly when the table says so", arguments: allStates, allEvents)
    func transition(state: ConnectionState, event: ConnectionEvent) {
        let expected: ConnectionState?
        if event == .disconnect {
            expected = .idle
        } else {
            expected = legal.first { $0.0 == state && $0.1 == event }?.2
        }
        #expect(state.applying(event) == expected)
    }

    @Test func tableCoversEachLegalPairOnce() {
        for (index, row) in legal.enumerated() {
            let duplicates = legal.enumerated().filter { $0.offset != index && $0.element.0 == row.0 && $0.element.1 == row.1 }
            #expect(duplicates.isEmpty, "duplicate row for \(row.0) / \(row.1)")
        }
    }
}
