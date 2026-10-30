// Mirrors tests/js/get_camera_slots.test.js.

import Foundation
import Testing
@testable import FilmcaseKit

private let fourSlots: [(name: String, filmSim: Int)] = [
    ("Portra", 11), ("Acros", 12), ("", 1), ("Eterna", 16),
]

private func slotRuntime(_ sleeper: RecordingSleeper, _ overrides: [String: Any] = [:]) throws -> CameraRuntime {
    CameraRuntime(config: try TestSupport.makeConfig(overrides), sleeper: sleeper)
}

@Suite("getCameraSlots")
struct GetCameraSlotsTests {
    @Test func readsOneStatePerSlotTheModelOffers() async throws {
        let device = SlotAwareDevice(slots: fourSlots)
        let states = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        #expect(states.map(\.index) == [1, 2, 3, 4])
    }

    @Test func returnsNameAndFilmSimulationOfEachSlot() async throws {
        let device = SlotAwareDevice(slots: fourSlots)
        let states = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        #expect(states.map(\.name) == ["Portra", "Acros", "", "Eterna"])
        #expect(states.map(\.filmSimName) == ["Classic Chrome", "Acros STD", "Provia", "Eterna"])
    }

    @Test func movesTheCursorToEachSlotInTurn() async throws {
        let device = SlotAwareDevice(slots: fourSlots)
        _ = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        #expect(await device.cursors == [1, 2, 3, 4])
    }

    @Test func readsEachSlotOnlyAfterPointingAtIt() async throws {
        let device = SlotAwareDevice(slots: fourSlots)
        _ = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        let reads = await device.readsAtCursor
        for read in reads {
            #expect([TestSupport.propSlotName, TestSupport.code("FilmSimulation")].contains(read.code))
        }
        // Two reads per slot, grouped: 1,1,2,2,3,3,4,4.
        #expect(reads.map(\.cursor) == [1, 1, 2, 2, 3, 3, 4, 4])
    }

    @Test func pausesAfterEachCursorMoveBeforeReading() async throws {
        let device = SlotAwareDevice(slots: fourSlots)
        let sleeper = RecordingSleeper()
        let runtime = try slotRuntime(sleeper, ["CAMERA_POST_CURSOR_DELAY_S": 0.05, "CAMERA_INTER_SLOT_DELAY_S": 0.02])
        _ = try await getCameraSlots(device, runtime: runtime)
        // First slot: cursor pause only. Each later slot: inter-slot then cursor.
        #expect(await sleeper.slept == [0.05, 0.02, 0.05, 0.02, 0.05, 0.02, 0.05])
    }

    @Test func returnsNothingForAModelWithNoCustomSlots() async throws {
        let device = SlotAwareDevice(slots: fourSlots, cameraName: "X-H9")
        let states = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        #expect(states.isEmpty)
        #expect(await device.cursors.isEmpty)
    }

    @Test func returnsNothingWhenTheCameraReportedNoName() async throws {
        let device = SlotAwareDevice(slots: fourSlots, cameraName: "")
        #expect(try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper())).isEmpty)
    }

    @Test func retriesATransportFailureAndCarriesOn() async throws {
        let device = SlotAwareDevice(slots: fourSlots, setFailuresBeforeSuccess: [TestSupport.propSlotCursor: 2])
        let states = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        #expect(states.count == 4)
    }

    @Test func backsOffExponentiallyBetweenAttempts() async throws {
        let device = SlotAwareDevice(slots: fourSlots, setFailuresBeforeSuccess: [TestSupport.propSlotCursor: 2])
        let sleeper = RecordingSleeper()
        _ = try await getCameraSlots(device, runtime: slotRuntime(sleeper))
        #expect(await sleeper.slept.filter { $0 > 0 } == [0.15, 0.3])
    }

    @Test func givesUpWhenTheCameraStaysUnreachable() async throws {
        let device = SlotAwareDevice(slots: fourSlots, defaultGetError: CameraConnectionError("gone"))
        await #expect(throws: CameraConnectionError.self) {
            _ = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        }
    }

    @Test func doesNotRetryARefusedCursorWrite() async throws {
        let device = SlotAwareDevice(slots: fourSlots, setRejectionCodes: [TestSupport.propSlotCursor: 0x2005])
        await #expect(throws: CameraWriteError.self) {
            _ = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        }
        // Attempts, not successes: a refused write never moves the cursor.
        #expect(await device.cursorAttempts == 1)
    }

    @Test func namesAnUnrecognisedFilmSimulationRatherThanBlankingIt() async throws {
        let slots = [("Mystery", 99)] + fourSlots.dropFirst().map { ($0.name, $0.filmSim) }
        let device = SlotAwareDevice(slots: slots)
        let states = try await getCameraSlots(device, runtime: slotRuntime(RecordingSleeper()))
        #expect(states[0].filmSimName == "Unknown(99)")
        #expect(states[1].filmSimName == "Acros STD")
    }
}
