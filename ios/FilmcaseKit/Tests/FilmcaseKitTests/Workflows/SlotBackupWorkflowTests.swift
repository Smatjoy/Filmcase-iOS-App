// SlotBackupWorkflow: back up first, never push without a backup, restore round-trips.

import Foundation
import Testing
@testable import FilmcaseKit

private let slot = 2
private let cursor = TestSupport.propSlotCursor

@Suite("SlotBackupWorkflow")
struct SlotBackupWorkflowTests {
    // --- push ---

    @Test func pushesAndVerifies() async throws {
        let rig = try await WorkflowRig()
        let recipe = try TestSupport.makeRecipe()
        #expect(try await rig.workflow.push(recipe, to: slot) == .verified)
        #expect(await rig.nameWrites == [recipe.name])
    }

    @Test func theBackupIsTakenBeforeTheFirstPropertyWrite() async throws {
        let rig = try await WorkflowRig()
        _ = try await rig.workflow.push(TestSupport.makeRecipe(), to: slot)

        let events = await rig.device.events
        let firstWrite = try #require(events.firstIndex { event in
            switch event {
            case .setInt, .setString: return true
            case .setUInt16(let code, _): return code != cursor
            default: return false
            }
        })
        let readsBefore = events[..<firstWrite].filter {
            if case .getInt = $0 { return true }
            if case .getString = $0 { return true }
            return false
        }
        // the name plus every property in the write order
        #expect(readsBefore.count == 1 + TestSupport.encodings.writeOrder.count)
        // and the only write before them is pointing the cursor at the slot
        #expect(events[..<firstWrite].contains(.setUInt16(cursor, slot)))
    }

    @Test func theStoredBackupHoldsTheSlotsOriginalContents() async throws {
        let rig = try await WorkflowRig()
        _ = try await rig.workflow.push(TestSupport.makeRecipe(), to: slot)

        let backup = try #require(await rig.store.latest(slot: slot, camera: ConnectionRig.cameraName))
        #expect(backup.slotName == WorkflowRig.originalName)
        #expect(backup.slotIndex == slot)
        #expect(backup.properties.map(\.name) == TestSupport.encodings.writeOrder)
        for property in backup.properties {
            #expect(property.value == WorkflowRig.originalValues[property.code])
        }
        #expect(backup.filmSimPtp == WorkflowRig.originalValues[TestSupport.code("FilmSimulation")])
    }

    @Test func aBackupThatCannotBeSavedMeansNothingIsWritten() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore())
        await #expect(throws: SlotBackupError.self) {
            try await rig.workflow.push(TestSupport.makeRecipe(), to: slot)
        }
        #expect(await rig.propertyWrites.isEmpty)
    }

    @Test func aBackupThatCannotBeReadMeansNothingIsWritten() async throws {
        // Call 1 is the cursor, 2 the name read; the camera goes while reading properties.
        let rig = try await WorkflowRig(unplugOnCall: 4)
        let result = try await rig.workflow.push(TestSupport.makeRecipe(), to: slot)
        #expect(result == .connectionLost)
        #expect(await rig.propertyWrites.isEmpty)
        #expect(try await rig.store.all().isEmpty)
    }

    @Test func aRecipeTheCameraCannotTakeIsRejectedBeforeAnythingIsRead() async throws {
        let rig = try await WorkflowRig()
        var recipe = try TestSupport.makeRecipe()
        recipe.filmSimulation = "Not A Film Simulation"
        await #expect(throws: (any Error).self) {
            try await rig.workflow.push(recipe, to: slot)
        }
        #expect(await rig.device.events.isEmpty)
    }

    @Test(arguments: [0, 8, -1])
    func aSlotOutsideTheCamerasSlotsIsRejected(badSlot: Int) async throws {
        let rig = try await WorkflowRig()
        await #expect(throws: SlotBackupError.slotOutOfRange(slot: badSlot, slotCount: 7)) {
            try await rig.workflow.push(TestSupport.makeRecipe(), to: badSlot)
        }
        #expect(await rig.device.events.isEmpty)
    }

    @Test func aRefusedPropertyIsReportedByName() async throws {
        let rig = try await WorkflowRig(setRejectionCodes: [TestSupport.code("HighLightTone"): 0x2005])
        let result = try await rig.workflow.push(TestSupport.makeRecipe(), to: slot)
        #expect(result == .partiallyFailed(["HighLightTone"]))
        #expect(try await rig.store.all().count == 1, "the backup was taken before the refusal")
    }

    @Test func theCameraGoingMidPushIsConnectionLostAndTheBackupSurvives() async throws {
        // Backup is calls 1...(2 + properties); the push starts after it.
        let backupCalls = 2 + TestSupport.encodings.writeOrder.count
        let rig = try await WorkflowRig(unplugOnCall: backupCalls + 4)
        let result = try await rig.workflow.push(TestSupport.makeRecipe(), to: slot)
        #expect(result == .connectionLost)
        #expect(try await rig.store.all().count == 1)
    }

    @Test func pushingWhileDisconnectedIsConnectionLost() async throws {
        let rig = try await WorkflowRig()
        await rig.rig.connection.disconnect()
        #expect(try await rig.workflow.push(TestSupport.makeRecipe(), to: slot) == .connectionLost)
    }

    // --- restore ---

    @Test func restoreWritesTheOriginalContentsBack() async throws {
        let rig = try await WorkflowRig()
        let recipe = try TestSupport.makeRecipe()
        _ = try await rig.workflow.push(recipe, to: slot)
        let backup = try #require(await rig.store.latest(slot: slot, camera: ConnectionRig.cameraName))

        #expect(try await rig.workflow.restore(backup) == .verified)

        #expect(try await rig.device.getString(TestSupport.propSlotName) == WorkflowRig.originalName)
        for (code, value) in WorkflowRig.originalValues {
            #expect(try await rig.device.getInt(code) == value, "property \(formatCode(code))")
        }
    }

    @Test func restoreReportsWhatTheCameraRefuses() async throws {
        let rig = try await WorkflowRig(setRejectionCodes: [TestSupport.code("Sharpness"): 0x2005])
        let backup = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: slot, capturedAt: Date(),
            slotName: "KEEP", properties: [
                BackupProperty(name: "Sharpness", code: TestSupport.code("Sharpness"), value: 1),
                BackupProperty(name: "Definition", code: TestSupport.code("Definition"), value: 2),
            ])
        #expect(try await rig.workflow.restore(backup) == .partiallyFailed(["Sharpness"]))
    }

    @Test func restoreRefusesABackupFromAnotherCameraModel() async throws {
        let rig = try await WorkflowRig()
        let backup = SlotBackup(
            cameraName: "X-S10", slotIndex: slot, capturedAt: Date(), slotName: "X", properties: [])
        await #expect(throws: SlotBackupError.wrongCamera(backup: "X-S10", connected: ConnectionRig.cameraName)) {
            try await rig.workflow.restore(backup)
        }
        #expect(await rig.device.events.isEmpty)
    }

    @Test func restoreWithTheCameraGoneIsConnectionLost() async throws {
        let rig = try await WorkflowRig(unplugOnCall: 3)
        let backup = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: slot, capturedAt: Date(),
            slotName: "X", properties: [BackupProperty(name: "Sharpness", code: TestSupport.code("Sharpness"), value: 1)])
        #expect(try await rig.workflow.restore(backup) == .connectionLost)
    }
}

@Suite("InMemoryBackupStore")
struct InMemoryBackupStoreTests {
    private func backup(slot: Int, camera: String = "X-T50", name: String) -> SlotBackup {
        SlotBackup(cameraName: camera, slotIndex: slot, capturedAt: Date(), slotName: name, properties: [])
    }

    @Test func latestIsTheMostRecentForThatSlotAndCamera() async throws {
        let store = InMemoryBackupStore()
        await store.save(backup(slot: 1, name: "old"))
        await store.save(backup(slot: 1, name: "new"))
        await store.save(backup(slot: 2, name: "other slot"))
        await store.save(backup(slot: 1, camera: "X-S10", name: "other camera"))
        #expect(await store.latest(slot: 1, camera: "X-T50")?.slotName == "new")
        #expect(await store.latest(slot: 3, camera: "X-T50") == nil)
    }

    @Test func allIsNewestFirstAndDeleteRemoves() async throws {
        let store = InMemoryBackupStore()
        let first = backup(slot: 1, name: "a")
        await store.save(first)
        await store.save(backup(slot: 2, name: "b"))
        #expect(await store.all().map(\.slotName) == ["b", "a"])
        await store.delete(id: first.id)
        #expect(await store.all().map(\.slotName) == ["b"])
    }

    @Test func aBackupSurvivesEncodingAndDecoding() throws {
        let original = SlotBackup(
            cameraName: "X-T50", slotIndex: 3, capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            slotName: "N", properties: [BackupProperty(name: "Sharpness", code: 53664, value: -2)])
        let decoded = try JSONDecoder().decode(SlotBackup.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
