// Connecting again after a disconnect or a loss. The transport's event stream has one consumer
// and announces a camera once, so the connection has to remember that the camera is attached.

import Foundation
import Testing
@testable import FilmcaseKit

private let camera = ConnectionRig.cameraName
private let ready = ConnectionState.ready(cameraName: camera)

@Suite("CameraConnection reconnecting")
struct CameraReconnectTests {
    @Test func connectingAgainAfterDisconnectOpensTheStillAttachedCamera() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.connection.disconnect()
        #expect(await rig.connection.current == .idle)

        await rig.connection.connect()
        await waitUntil { await rig.connection.current == ready }
        #expect(await rig.connection.current == ready)
        #expect(await rig.transport.openCount == 2)
        #expect(await rig.connection.history.suffix(4) == [.awaitingAuthorization, .searching, .opening, ready])
    }

    @Test func reconnectingWorksRepeatedly() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        for _ in 0..<3 {
            await rig.connection.disconnect()
            await rig.connection.connect()
            #expect(await rig.connection.current == ready)
        }
        #expect(await rig.transport.openCount == 4)
    }

    @Test func aSessionTheCameraClosedCanBeReopenedWhileItStaysAttached() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.transport.closeSessionFromCamera()
        await waitUntil { await rig.connection.current == .lost(.sessionClosed) }
        #expect(await rig.connection.current == .lost(.sessionClosed))
        #expect(await rig.connection.isDeviceAttached)

        await rig.connection.connect()
        #expect(await rig.connection.current == ready)
        let value = try await rig.connection.run("read") { _ in 42 }
        #expect(value == 42)
    }

    @Test func unpluggingWhileIdleAndConnectingWaitsForTheCamera() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.connection.disconnect()
        await rig.transport.unplug()
        await waitUntil { await !rig.connection.isDeviceAttached }

        await rig.connection.connect()
        #expect(await rig.connection.current == .searching)
        await rig.transport.plugIn()
        await waitUntil { await rig.connection.current == ready }
        #expect(await rig.connection.current == ready)
    }

    @Test func unplugThenReplugReopensWithoutAnyCallToConnect() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        await rig.transport.unplug()
        await waitUntil { await rig.connection.current == .lost(.disconnected) }
        #expect(await !rig.connection.isDeviceAttached)
        await rig.transport.plugIn()
        await waitUntil { await rig.connection.current == ready }
        #expect(await rig.connection.current == ready)
        #expect(await rig.connection.isDeviceAttached)
    }

    @Test func aCameraPluggedInWhileIdleIsOpenedByTheNextConnect() async throws {
        let rig = try ConnectionRig(attached: false)
        await rig.connection.connect()
        #expect(await rig.connection.current == .searching)
        await rig.connection.disconnect()
        await rig.transport.plugIn()
        await waitUntil { await rig.connection.isDeviceAttached }

        await rig.connection.connect()
        #expect(await rig.connection.current == ready)
    }

    @Test func disconnectingDuringAnOperationStillAllowsConnectingAgain() async throws {
        let rig = try ConnectionRig()
        await rig.connectAndWaitUntilReady()
        let running = Task {
            try await rig.connection.run("slow") { _ in try await Task.sleep(for: .seconds(3600)) }
        }
        await waitUntil { if case .busy = await rig.connection.current { true } else { false } }
        await rig.connection.disconnect()
        _ = await running.result
        #expect(await rig.connection.current == .idle)

        await rig.connection.connect()
        #expect(await rig.connection.current == ready)
    }
}
