// CameraConnection driven through FakeCameraTransport: the happy path, authorization,
// exclusivity, and the ADR 016 recovery policy (stall -> reopen -> restore cursor -> retry once).

import Foundation
import Testing
@testable import FilmcaseKit

private let camera = ConnectionRig.cameraName
private let ready = ConnectionState.ready(cameraName: camera)

private func isBusy(_ state: ConnectionState) -> Bool {
    if case .busy = state { return true }
    return false
}

private func isRecovering(_ state: ConnectionState) -> Bool {
    if case .recovering = state { return true }
    return false
}

/// True while the connection is `busy` or `recovering`.
private func isRunning(_ connection: CameraConnection) async -> Bool {
    switch await connection.current {
    case .busy, .recovering: return true
    default: return false
    }
}

@Suite("CameraConnection")
struct CameraConnectionTests {
    // --- connecting ---

    @Test func connectsThroughAuthorizationToReady() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        #expect(await rig.connection.history == [.idle, .awaitingAuthorization, .searching, .opening, ready])
        #expect(await rig.connection.cameraName == camera)
    }

    @Test func statesStreamReportsEveryChangeFromTheCurrentState() async throws {
        let rig = try ConnectionRig()
        var seen: [ConnectionState] = []
        let stream = rig.connection.states
        await rig.connection.connect()
        for await state in stream {
            seen.append(state)
            if state == ready { break }
        }
        #expect(seen == [.idle, .awaitingAuthorization, .searching, .opening, ready])
    }

    @Test func authorizationDeniedEndsUnauthorizedWithoutOpeningASession() async throws {
        let rig = try ConnectionRig(grantsAuthorization: false)
        await rig.connection.connect()
        #expect(await rig.connection.current == .unauthorized)
        #expect(await rig.transport.openCount == 0)
        await #expect(throws: ConnectionError.notReady(.unauthorized)) {
            try await rig.connection.run("read") { _ in 1 }
        }
    }

    @Test func aPreviouslyDeniedStatusIsNotAskedAgain() async throws {
        let rig = try ConnectionRig(authorizationStatus: .denied, grantsAuthorization: true)
        await rig.connection.connect()
        #expect(await rig.connection.current == .unauthorized)
    }

    @Test func aPreviouslyAuthorizedStatusSkipsTheRequest() async throws {
        let rig = try ConnectionRig(authorizationStatus: .authorized, grantsAuthorization: false)
        await rig.connectAndWaitUntilReady()
        #expect(await rig.connection.current == ready)
    }

    @Test func waitsInSearchingUntilACameraIsPluggedIn() async throws {
        let rig = try ConnectionRig(attached: false)
        await rig.connection.connect()
        #expect(await rig.connection.current == .searching)
        await rig.transport.plugIn()
        await waitUntil { await rig.connection.current == ready }
        #expect(await rig.connection.current == ready)
    }

    @Test func aSessionThatCannotOpenIsLost() async throws {
        let rig = try ConnectionRig(failOpens: [1])
        await rig.connection.connect()
        await waitUntil { if case .lost = await rig.connection.current { true } else { false } }
        guard case .lost(.openFailed) = await rig.connection.current else {
            Issue.record("expected lost(openFailed), got \(await rig.connection.current)")
            return
        }
    }

    @Test func disconnectReturnsToIdleAndClosesTheSession() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.connection.disconnect()
        #expect(await rig.connection.current == .idle)
        #expect(await rig.transport.closeCount == 1)
    }

    // --- running operations ---

    @Test func anOperationReturnsItsValueAndTheConnectionReturnsToReady() async throws {
        let rig = try ConnectionRig(intValues: [TestSupport.code("FilmSimulation"): 7])
        await rig.connectAndWaitUntilReady()
        let code = TestSupport.code("FilmSimulation")
        let value = try await rig.connection.run("read") { try await $0.getInt(code) }
        #expect(value == 7)
        #expect(await rig.connection.history.suffix(2) == [.busy(cameraName: camera, operation: "read"), ready])
    }

    @Test func aSecondRunWhileBusyThrowsBusy() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        let first = Task {
            try await rig.connection.run("slow") { _ in try await Task.sleep(for: .seconds(3600)) }
        }
        await waitUntil { await isRunning(rig.connection) }
        await #expect(throws: ConnectionError.busy) {
            try await rig.connection.run("second") { _ in 1 }
        }
        first.cancel()
        _ = await first.result
        #expect(await rig.connection.current == ready)
    }

    @Test func anOperationsOwnErrorPropagatesAndLeavesTheConnectionReady() async throws {
        struct Boom: Error {}
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await #expect(throws: Boom.self) {
            try await rig.connection.run("fail") { _ in throw Boom() }
        }
        #expect(await rig.connection.current == ready)
    }

    // --- recovery (ADR 016) ---

    @Test func aStalledOperationReopensTheSessionRestoresTheCursorAndRetries() async throws {
        // Call 1 sets the cursor to 5; call 2 (the name write) stalls; call 3 is the restore.
        let rig = try ConnectionRig(stallOnCalls: [2])
        await rig.connectAndWaitUntilReady()
        let cursor = TestSupport.propSlotCursor
        let nameCode = TestSupport.propSlotName
        _ = try await rig.connection.run("select slot") { try await $0.setUInt16(cursor, 5) }

        let run = Task {
            try await rig.connection.run("name") { try await $0.setString(nameCode, "FCTEST") }
        }
        await waitUntil { rig.clock.sleeps.count >= 2 }   // run 1's timeout, then this run's
        await rig.advanceClock(while: isBusy)
        _ = try await run.value

        let writes = await rig.device.writes
        #expect(writes.map(\.code) == [cursor, cursor, nameCode], "select, restore, retried name write")
        #expect(writes.map(\.value) == [.int(5), .int(5), .string("FCTEST")])
        #expect(await rig.transport.openCount == 2)
        #expect(await rig.transport.closeCount == 1)
        #expect(await rig.connection.history.suffix(3) == [
            .busy(cameraName: camera, operation: "name"),
            .recovering(cameraName: camera, operation: "name", attempt: 1),
            ready,
        ])
    }

    @Test func recoveryWithNoCursorWrittenYetDoesNotInventOne() async throws {
        let rig = try ConnectionRig(stallOnCalls: [1])
        await rig.connectAndWaitUntilReady()
        let nameCode = TestSupport.propSlotName
        let run = Task { try await rig.connection.run("name") { try await $0.setString(nameCode, "A") } }
        await waitUntil { rig.clock.sleeps.count >= 1 }
        await rig.advanceClock(while: isBusy)
        _ = try await run.value
        #expect(await rig.device.writes.map(\.code) == [nameCode])
    }

    @Test func stallingTwiceIsLost() async throws {
        let rig = try ConnectionRig(stallOnCalls: [1, 2])
        await rig.connectAndWaitUntilReady()
        let nameCode = TestSupport.propSlotName
        let run = Task { try await rig.connection.run("name") { try await $0.setString(nameCode, "A") } }
        await waitUntil { rig.clock.sleeps.count >= 1 }
        await rig.advanceClock(while: isBusy)
        await waitUntil { rig.clock.sleeps.count >= 3 }   // timeout, reopen guard, retry timeout
        await rig.advanceClock(while: isRecovering)
        let result = await run.result
        guard case .failure(let error) = result, error is CameraConnectionError else {
            Issue.record("expected CameraConnectionError, got \(result)")
            return
        }
        #expect(await rig.connection.current == .lost(.stalled))
        #expect(await rig.device.writes.isEmpty, "stalled calls never reach the camera")
    }

    @Test func aSessionThatCannotBeReopenedAfterAStallIsLost() async throws {
        let rig = try ConnectionRig(stallOnCalls: [1], failOpens: [2])
        await rig.connectAndWaitUntilReady()
        let nameCode = TestSupport.propSlotName
        let run = Task { try await rig.connection.run("name") { try await $0.setString(nameCode, "A") } }
        await waitUntil { rig.clock.sleeps.count >= 1 }
        await rig.advanceClock(while: isBusy)
        let result = await run.result
        guard case .failure(let error) = result, error is CameraConnectionError else {
            Issue.record("expected CameraConnectionError, got \(result)")
            return
        }
        guard case .lost(.recoveryFailed) = await rig.connection.current else {
            Issue.record("expected lost(recoveryFailed), got \(await rig.connection.current)")
            return
        }
    }

    // --- the camera goes away ---

    @Test func unpluggingMidOperationIsLostAtOnceAndTheOperationFails() async throws {
        let rig = try ConnectionRig(unplugOnCall: 2)
        await rig.connectAndWaitUntilReady()
        let code = TestSupport.code("FilmSimulation")
        let result: Result<Int, any Error>
        do {
            result = .success(try await rig.connection.run("read twice") { device in
                _ = try await device.getInt(code)
                return try await device.getInt(code)
            })
        } catch {
            result = .failure(error)
        }
        guard case .failure(let error) = result, error is CameraConnectionError else {
            Issue.record("expected CameraConnectionError, got \(result)")
            return
        }
        #expect(await rig.connection.current == .lost(.disconnected))
        #expect(await rig.transport.closeCount >= 1)
        await #expect(throws: ConnectionError.notReady(.lost(.disconnected))) {
            try await rig.connection.run("again") { _ in 1 }
        }
    }

    @Test func pluggingTheCameraBackInAfterALossReopensTheSession() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.transport.unplug()
        await waitUntil { await rig.connection.current == .lost(.disconnected) }
        #expect(await rig.connection.current == .lost(.disconnected))
        await rig.transport.plugIn()
        await waitUntil { await rig.connection.current == ready }
        #expect(await rig.connection.current == ready)
    }

    @Test func theSessionClosingUnderneathUsIsLost() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.transport.closeSessionFromCamera()
        await waitUntil { await rig.connection.current == .lost(.sessionClosed) }
        #expect(await rig.connection.current == .lost(.sessionClosed))
    }

    @Test func aTransportErrorIsLost() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.transport.reportError("usb reset")
        await waitUntil { await rig.connection.current == .lost(.transportError("usb reset")) }
        #expect(await rig.connection.current == .lost(.transportError("usb reset")))
    }
}
