import Foundation
import Testing
@testable import FilmcaseKit

@MainActor
private struct CameraRig {
    let rig: ConnectionRig
    let model: CameraModel
    let observing: Task<Void, Never>

    init(
        authorization: CameraAuthorizationStatus = .authorized, grants: Bool = true, attached: Bool = true
    ) throws {
        rig = try ConnectionRig(
            intValues: [TestSupport.code("FilmSimulation"): 17],
            stringValues: [TestSupport.propSlotName: "Kodak Portra 400"],
            authorizationStatus: authorization, grantsAuthorization: grants, attached: attached)
        let model = CameraModel(connection: rig.connection, runtime: try TestSupport.runtime(rig.device))
        self.model = model
        observing = Task { await model.observe() }
    }

    func stop() { observing.cancel() }
}

@MainActor
@Suite("CameraModel")
struct CameraModelTests {
    // --- the pill ---

    @Test(arguments: [
        (ConnectionState.idle, ConnectionPill.Kind.none, "Not connected"),
        (.awaitingAuthorization, .none, "Waiting for camera access"),
        (.unauthorized, .none, "Camera access denied"),
        (.searching, .none, "Looking for a camera"),
        (.opening, .usb, "Connecting"),
        (.ready(cameraName: "X-T50"), .usb, "USB: X-T50"),
        (.busy(cameraName: "X-T50", operation: "Push to C3"), .usb, "X-T50: Push to C3"),
        (.recovering(cameraName: "X-T50", operation: "Push to C3", attempt: 1), .usb, "X-T50: recovering"),
        (.lost(.disconnected), .none, "Camera disconnected"),
        (.lost(.stalled), .none, "Camera stopped responding"),
        (.lost(.openFailed("x")), .none, "Camera could not be opened"),
    ])
    func everyStateHasAPill(state: ConnectionState, kind: ConnectionPill.Kind, text: String) {
        let pill = ConnectionPill(for: state)
        #expect(pill.kind == kind)
        #expect(pill.text == text)
        #expect(pill.isReady == (state == .ready(cameraName: "X-T50")))
    }

    // --- slot cells ---

    @Test func aSlotReadsAloudWithItsNumberNameAndFilmSimulation() {
        let slot = SlotItem(index: 3, name: "Kodak Portra 400", filmSimName: "Classic Negative")
        #expect(slot.title == "C3")
        #expect(slot.displayName == "Kodak Portra 400")
        #expect(slot.accessibilityLabel == "C3, Kodak Portra 400, Classic Negative")
    }

    @Test func anUnnamedSlotIsCalledEmpty() {
        let slot = SlotItem(SlotState(index: 1, name: "", filmSimPtp: 1, filmSimName: "Provia"))
        #expect(slot.displayName == "Empty")
        #expect(slot.accessibilityLabel == "C1, empty, Provia")
    }

    // --- following the connection ---

    @Test func connectingShowsTheCameraAndReadsItsSlots() async throws {
        let rig = try CameraRig()
        defer { rig.stop() }
        #expect(rig.model.pill.text == "Not connected")

        await rig.model.connect()
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }

        #expect(rig.model.isReady)
        #expect(rig.model.pill == ConnectionPill(kind: .usb, text: "USB: X-T50", isReady: true))
        #expect(rig.model.slots.map(\.title) == (1...7).map { "C\($0)" })
        #expect(rig.model.slots[2].accessibilityLabel == "C3, Kodak Portra 400, Classic Negative")
        #expect(rig.model.errorMessage == nil)
    }

    @Test func deniedAccessIsShown() async throws {
        let rig = try CameraRig(authorization: .notDetermined, grants: false)
        defer { rig.stop() }
        await rig.model.connect()
        await eventually { rig.model.connectionState == .unauthorized }
        #expect(rig.model.pill == ConnectionPill(kind: .none, text: "Camera access denied", isReady: false))
        #expect(rig.model.slots.isEmpty)
    }

    @Test func unpluggingTheCameraClearsTheSlotsAndShowsTheLoss() async throws {
        let rig = try CameraRig()
        defer { rig.stop() }
        await rig.model.connect()
        await eventually { rig.model.slotsState == .loaded }

        await rig.rig.transport.unplug()
        await eventually { rig.model.connectionState == .lost(.disconnected) }
        await eventually { rig.model.slots.isEmpty }

        #expect(rig.model.pill.text == "Camera disconnected")
        #expect(rig.model.slotsState == .idle)
    }

    @Test func pluggingItBackReadsTheSlotsAgain() async throws {
        let rig = try CameraRig()
        defer { rig.stop() }
        await rig.model.connect()
        await eventually { rig.model.slotsState == .loaded }
        await rig.rig.transport.unplug()
        await eventually { rig.model.slots.isEmpty && rig.model.connectionState == .lost(.disconnected) }

        await rig.rig.transport.plugIn()
        await eventually { rig.model.slotsState == .loaded && rig.model.isReady }
        #expect(rig.model.isReady)
    }

    @Test func disconnectingReturnsToIdle() async throws {
        let rig = try CameraRig()
        defer { rig.stop() }
        await rig.model.connect()
        await eventually { rig.model.slotsState == .loaded }
        await rig.model.disconnect()
        await eventually { rig.model.connectionState == .idle }
        #expect(rig.model.slots.isEmpty)
    }

    @Test func readingSlotsWithoutACameraReportsWhy() async throws {
        let rig = try CameraRig()
        defer { rig.stop() }
        await rig.model.refreshSlots()
        #expect(rig.model.slotsState == .failed("The camera is not ready (Not connected)."))
        #expect(rig.model.errorMessage == "The camera is not ready (Not connected).")
    }

    @Test func refreshingPicksUpChangesOnTheCamera() async throws {
        let rig = try CameraRig()
        defer { rig.stop() }
        await rig.model.connect()
        await eventually { rig.model.slotsState == .loaded }

        _ = try await rig.rig.device.setString(TestSupport.propSlotName, "Renamed")
        await rig.model.refreshSlots()
        #expect(rig.model.slots.allSatisfy { $0.name == "Renamed" })
        #expect(rig.model.errorMessage == nil)
    }
}
