import Foundation
import Testing
@testable import FilmcaseKit

/// A store that returns what it was given (newest first), or fails.
private struct ListedBackupStore: BackupStore {
    struct Failure: Error {}
    var backups: [SlotBackup] = []
    var fails = false

    func save(_ backup: SlotBackup) async throws {}
    func latest(slot: Int, camera: String) async throws -> SlotBackup? { nil }
    func all() async throws -> [SlotBackup] {
        if fails { throw Failure() }
        return backups
    }
    func delete(id: SlotBackup.ID) async throws {}
}

@MainActor
@Suite("BackupsModel")
struct BackupsModelTests {
    private func backup(_ camera: String, _ slot: Int, _ name: String, age: TimeInterval = 0) -> SlotBackup {
        SlotBackup(
            cameraName: camera, slotIndex: slot, capturedAt: Date(timeIntervalSince1970: 1_000 - age),
            slotName: name, properties: [])
    }

    @Test func listsTheLatestBackupPerCameraAndSlotKeepingTheStoreOrder() async throws {
        let rig = try await WorkflowRig()
        let listed = [
            backup("X-T50", 3, "new C3"), backup("X-S10", 3, "S10 C3"), backup("X-T50", 1, "new C1"),
            backup("X-T50", 3, "old C3", age: 10), backup("X-T50", 1, "old C1", age: 20),
        ]
        let model = BackupsModel(store: ListedBackupStore(backups: listed), workflow: rig.workflow)
        await model.load()
        #expect(model.backups.map(\.slotName) == ["new C3", "S10 C3", "new C1"])
        #expect(model.message == nil)
    }

    @Test func aStoreThatFailsToListIsReportedInWords() async throws {
        let rig = try await WorkflowRig()
        let model = BackupsModel(store: ListedBackupStore(fails: true), workflow: rig.workflow)
        await model.load()
        #expect(model.backups.isEmpty)
        #expect(model.message == "Something went wrong.")
    }

    @Test func restoringPutsTheSlotBackAndSaysSo() async throws {
        let rig = try await WorkflowRig()
        let recipe = try TestSupport.makeRecipe()
        _ = try await rig.workflow.push(recipe, to: 3)
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.load()
        let backup = try #require(model.backups.first)
        #expect(backup.slotName == WorkflowRig.originalName)

        await model.restore(backup)
        #expect(model.message == "C3 restored.")
        #expect(model.successCount == 1)
        #expect(!model.isRestoring)
        #expect(try await rig.device.getString(TestSupport.propSlotName) == WorkflowRig.originalName)
    }

    @Test func aRestoreWaitsForConfirmation() async throws {
        let rig = try await WorkflowRig()
        _ = try await rig.workflow.push(try TestSupport.makeRecipe(), to: 3)
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.load()
        let backup = try #require(model.backups.first)

        model.requestRestore(backup)
        #expect(model.pendingRestore == backup)
        model.cancelRestore()
        #expect(model.pendingRestore == nil)
        #expect(model.message == nil)

        model.requestRestore(backup)
        await model.confirmRestore()
        #expect(model.pendingRestore == nil)
        #expect(model.message == "C3 restored.")
    }

    @Test func theFilmSimulationIsNamed() async throws {
        let rig = try await WorkflowRig()
        let provia = try #require(TestSupport.encodings.filmSimulationToPtp["Provia"])
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        let backup = SlotBackup(
            cameraName: "X-T50", slotIndex: 1, capturedAt: Date(), slotName: "A",
            properties: [BackupProperty(name: "FilmSimulation", code: TestSupport.code("FilmSimulation"), value: provia)])
        #expect(model.filmSimulationName(backup) == "Provia")
    }

    @Test func aRefusedPropertyIsNamedAndIsNotACountedSuccess() async throws {
        let sharpness = TestSupport.code("Sharpness")
        let rig = try await WorkflowRig(setRejectionCodes: [sharpness: 0x2005])
        let backup = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 2, capturedAt: Date(), slotName: "OLD",
            properties: [BackupProperty(name: "Sharpness", code: sharpness, value: 3)])
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.restore(backup)
        #expect(model.message == "C2 restored, except Sharpness.")
        #expect(model.successCount == 0)
    }

    @Test func aLostConnectionIsReported() async throws {
        let rig = try await WorkflowRig(unplugOnCall: 2)
        let backup = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 2, capturedAt: Date(), slotName: "OLD",
            properties: [BackupProperty(name: "Sharpness", code: TestSupport.code("Sharpness"), value: 3)])
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.restore(backup)
        #expect(model.message == "The camera connection was lost.")
        #expect(model.successCount == 0)
    }

    @Test func aBackupFromAnotherCameraIsRefusedInWords() async throws {
        let rig = try await WorkflowRig()
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.restore(backup("X-S10", 1, "elsewhere"))
        #expect(model.message == "That backup is from a X-S10, but a \(ConnectionRig.cameraName) is connected.")
        #expect(!model.isRestoring)
    }

    @Test func aNewRestoreClearsTheOldMessage() async throws {
        let rig = try await WorkflowRig()
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.restore(backup("X-S10", 1, "elsewhere"))
        #expect(model.message != nil)
        await model.restore(backup(ConnectionRig.cameraName, 1, "ok"))
        #expect(model.message == "C1 restored.")
    }
}
