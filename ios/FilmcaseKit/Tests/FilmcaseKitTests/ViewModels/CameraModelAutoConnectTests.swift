import Foundation
import Testing
@testable import FilmcaseKit

@MainActor
@Suite("CameraModel auto-connect")
struct CameraModelAutoConnectTests {
    @Test func aCameraThatIsPluggedInIsReadyWithoutAnyTap() async throws {
        let rig = try CameraRig(autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }
        #expect(rig.model.isReady)
        #expect(rig.model.slots.count == 7)
        #expect(rig.model.autoConnectSuspension == nil)
    }

    @Test func aCameraPluggedInLaterIsPickedUpAfterAccessWasGranted() async throws {
        let rig = try CameraRig(attached: false, autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.connectionState == .searching }
        #expect(rig.model.pill.text == "Looking for a camera")

        await rig.rig.transport.plugIn()
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }
        #expect(rig.model.isReady)
    }

    @Test func refusedAccessStaysRefusedUntilThePersonTapsConnect() async throws {
        let rig = try CameraRig(authorization: .notDetermined, grants: false, autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.connectionState == .unauthorized }
        #expect(rig.model.autoConnectSuspension == .authorizationDeclined)

        // Observing again (another view appearing) must not ask again.
        let second = Task { await rig.model.observe() }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.connectionState == .unauthorized)

        // Disconnecting, then observing afresh, still does not reconnect by itself.
        await rig.model.disconnect()
        await eventually { rig.model.connectionState == .idle }
        let third = Task { await rig.model.observe() }
        defer { third.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.connectionState == .idle)

        // The person's tap is the only way back (and it is refused again here).
        await rig.model.connect()
        await eventually { rig.model.connectionState == .unauthorized }
        #expect(rig.model.connectionState == .unauthorized)
        #expect(rig.model.autoConnectSuspension == .authorizationDeclined)
    }

    @Test func disconnectingByHandKeepsTheCameraDisconnected() async throws {
        let rig = try CameraRig(autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.isReady }
        await rig.model.disconnect()
        await eventually { rig.model.connectionState == .idle }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.connectionState == .idle)
        #expect(rig.model.autoConnectSuspension == .userDisconnected)

        // The person's tap lifts the suspension and reconnects.
        await rig.model.connect()
        #expect(rig.model.autoConnectSuspension == nil)
        // The camera is still plugged in, so it opens at once (it used to stick at searching,
        // because the camera was never announced a second time).
        await eventually { rig.model.isReady }
        #expect(rig.model.isReady)
    }

    @Test func aModelMadeWithoutAutoConnectNeverConnectsByItself() async throws {
        let rig = try CameraRig(autoConnect: false)
        defer { rig.stop() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.connectionState == .idle)
        #expect(rig.model.autoConnectSuspension == .disabled)
        await rig.model.connect()
        await rig.model.disconnect()
        #expect(rig.model.autoConnectSuspension == .disabled)
    }

    @Test func aLostCameraComesBackWhenPluggedInAgain() async throws {
        let rig = try CameraRig(autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.slotsState == .loaded }
        await rig.rig.transport.unplug()
        await eventually { rig.model.connectionState == .lost(.disconnected) && rig.model.slots.isEmpty }
        #expect(rig.model.pill.text == "Camera disconnected")

        await rig.rig.transport.plugIn()
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }
        #expect(rig.model.isReady)
    }

    @Test func aSessionTheCameraClosedIsReopenedWhileItStaysPluggedIn() async throws {
        let rig = try CameraRig(autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }
        await rig.rig.transport.closeSessionFromCamera()
        await eventually { await rig.rig.transport.openCount == 2 }
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }
        #expect(rig.model.isReady)
        #expect(rig.model.slots.count == 7)
        #expect(await rig.rig.transport.openCount == 2)

        // Each loss gets its own reconnect, because a session became ready in between.
        await rig.rig.transport.closeSessionFromCamera()
        await eventually { await rig.rig.transport.openCount == 3 }
        await eventually { rig.model.isReady && rig.model.slotsState == .loaded }
        #expect(rig.model.isReady)
    }

    @Test func aLostCameraIsNotReopenedAfterThePersonDisconnected() async throws {
        let rig = try CameraRig(autoConnect: true)
        defer { rig.stop() }
        await eventually { rig.model.isReady }
        await rig.model.disconnect()
        await eventually { rig.model.connectionState == .idle }
        await rig.rig.transport.closeSessionFromCamera()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.model.connectionState == .idle)
        #expect(rig.model.autoConnectSuspension == .userDisconnected)
    }

    @Test func aSessionThatKeepsFailingToOpenIsNotRetriedForever() async throws {
        let rig = try CameraRig(autoConnect: true, failOpens: [2])
        defer { rig.stop() }
        await eventually { rig.model.isReady }
        await rig.rig.transport.closeSessionFromCamera()
        await eventually { await rig.rig.transport.openCount == 2 }
        await eventually { if case .lost(.openFailed) = rig.model.connectionState { true } else { false } }
        try await Task.sleep(for: .milliseconds(100))
        guard case .lost(.openFailed) = rig.model.connectionState else {
            Issue.record("expected lost(openFailed), got \(rig.model.connectionState)")
            return
        }
        #expect(await rig.rig.transport.openCount == 2)
    }
}
