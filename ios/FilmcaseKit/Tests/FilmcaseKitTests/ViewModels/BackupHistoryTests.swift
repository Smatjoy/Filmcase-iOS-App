// Backup history and "restore originals": the oldest backup per camera and slot is what the
// slot held before Filmcase, and it stays reachable however often a collection is pushed.

import Foundation
import Testing
@testable import FilmcaseKit

private func backup(
    _ camera: String, _ slot: Int, _ name: String, at seconds: TimeInterval = 0
) -> SlotBackup {
    SlotBackup(
        cameraName: camera, slotIndex: slot, capturedAt: Date(timeIntervalSince1970: seconds),
        slotName: name, properties: [])
}

@Suite("SlotBackupHistory")
struct SlotBackupHistoryTests {
    @Test func groupsPerSlotAscendingEachNewestFirstWithTheOldestFlagged() {
        let newestFirst = [
            backup("X-T50", 3, "C3 third", at: 6), backup("X-T50", 1, "C1 third", at: 5),
            backup("X-T50", 3, "C3 second", at: 4), backup("X-T50", 1, "C1 second", at: 3),
            backup("X-T50", 3, "C3 original", at: 2), backup("X-T50", 1, "C1 original", at: 1),
        ]
        let histories = SlotBackupHistory.group(newestFirst)
        #expect(histories.map(\.slotIndex) == [1, 3])
        #expect(histories[0].entries.map(\.backup.slotName) == ["C1 third", "C1 second", "C1 original"])
        #expect(histories[0].entries.map(\.isBeforeFilmcase) == [false, false, true])
        #expect(histories[0].entries.map(\.capturedAt) == [5, 3, 1].map { Date(timeIntervalSince1970: $0) })
        #expect(histories[1].original.backup.slotName == "C3 original")
        #expect(histories[1].latest.backup.slotName == "C3 third")
        #expect(histories[1].earlier.count == 2)
    }

    @Test func aSlotWithOneBackupHasItAsItsOriginal() {
        let histories = SlotBackupHistory.group([backup("X-T50", 2, "only")])
        #expect(histories.count == 1)
        #expect(histories[0].latest.isBeforeFilmcase)
    }

    @Test func twoCamerasDoNotShareOriginals() {
        let newestFirst = [
            backup("X-S10", 1, "S10 later", at: 4), backup("X-T50", 1, "T50 later", at: 3),
            backup("X-S10", 1, "S10 original", at: 2), backup("X-T50", 1, "T50 original", at: 1),
        ]
        let histories = SlotBackupHistory.group(newestFirst)
        #expect(histories.map(\.cameraName) == ["X-S10", "X-T50"])
        #expect(histories.map(\.original.backup.slotName) == ["S10 original", "T50 original"])
        #expect(SlotBackupHistory.originals(in: newestFirst, camera: "X-T50").map(\.slotName) == ["T50 original"])
        #expect(SlotBackupHistory.originals(in: newestFirst, camera: "X-E4").isEmpty)
    }
}

@MainActor
@Suite("BackupsModel history")
struct BackupsModelHistoryTests {
    /// Push the 7-recipe collection through the real workflows, once per call, with a fresh model.
    private func pushCollection(_ rig: WorkflowRig) async throws {
        let recipes = try WorkflowRig.recipes(7)
        let items = (1...7).map { CollectionPushModel.Item(id: $0, name: "R\($0)") }
        let model = CollectionPushModel(
            items: items, recipes: recipes, slotCount: 7, workflow: rig.workflow, clock: rig.collectionClock)
        await model.start()
        guard case .finished = model.phase else { Issue.record("not finished: \(model.phase)"); return }
    }

    private func slotValues(_ rig: WorkflowRig) async throws -> (name: String, ints: [UInt16: Int]) {
        var ints: [UInt16: Int] = [:]
        for code in WorkflowRig.originalValues.keys { ints[code] = try await rig.device.getInt(code) }
        return (try await rig.device.getString(TestSupport.propSlotName), ints)
    }

    @Test func threePushesBuryNothing_restoreOriginalsPutsTheOriginalsBack() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        try await pushCollection(rig)
        // The first push backed up each slot as it was: these are the originals. (The fake
        // camera keeps one value per property, so slots after C1 hold what the push before
        // them wrote; each is still the first backup of its slot.)
        let firstPush = Array(try await rig.store.all().reversed())
        #expect(firstPush.map(\.slotIndex) == [1, 2, 3, 4, 5, 6, 7])
        #expect(firstPush[0].slotName == WorkflowRig.originalName)
        try await pushCollection(rig)
        try await pushCollection(rig)

        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.load()
        #expect(model.histories.map(\.slotIndex) == [1, 2, 3, 4, 5, 6, 7])
        for (history, original) in zip(model.histories, firstPush) {
            #expect(history.entries.count == 3)
            #expect(history.original.backup.id == original.id)
            #expect(history.original.isBeforeFilmcase)
            #expect(history.entries.dropLast().allSatisfy { !$0.isBeforeFilmcase })
        }
        let first = try #require(model.histories.first)
        #expect(first.original.backup.slotName == WorkflowRig.originalName)
        #expect(first.entries.dropLast().allSatisfy { $0.backup.slotName == "R7" }, "Filmcase's own recipes")
        // The camera holds the last recipe, not an original.
        #expect(try await slotValues(rig).name == "R7")

        await model.requestRestoreOriginals()
        let prompt = try #require(model.restoreOriginalsPrompt)
        #expect(prompt.contains("7 slots"))
        #expect(prompt.contains("C1 \(WorkflowRig.originalName)"))
        for original in firstPush { #expect(prompt.contains("C\(original.slotIndex) \(original.slotName)")) }

        let writesBefore = await rig.nameWrites.count
        await model.restoreOriginals()
        #expect(model.restoreOriginalsPrompt == nil)
        #expect(model.message == "Restored the originals of 7 slots.")
        #expect(model.successCount == 1)
        #expect(await rig.nameWrites.dropFirst(writesBefore).map { $0 } == firstPush.map(\.slotName))
        // C7 was written last: the slot holds its original name and properties.
        let last = try #require(firstPush.last)
        let values = try await slotValues(rig)
        #expect(values.name == last.slotName)
        for property in last.properties { #expect(values.ints[property.code] == property.value) }
    }

    @Test func restoringOriginalsTakesItsOwnBackupAndKeepsTheOriginalOldest() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        try await pushCollection(rig)
        try await pushCollection(rig)
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.load()
        let before = model.histories
        await model.restoreOriginals()

        #expect(model.histories.map(\.entries.count) == before.map { $0.entries.count + 1 })
        for (history, old) in zip(model.histories, before) {
            #expect(history.original.backup.id == old.original.backup.id)
            #expect(history.latest.backup.id != old.latest.backup.id)
            #expect(!history.latest.isBeforeFilmcase)
        }
        #expect(model.backups.count == 7, "latest per slot still lists each slot once")
    }

    @Test func anOlderEntryCanBeRestored() async throws {
        let store = InMemoryBackupStore()
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0)
        let wanted = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 2, capturedAt: Date(timeIntervalSince1970: 1),
            slotName: "MIDDLE", properties: [BackupProperty(name: "Sharpness", code: TestSupport.code("Sharpness"), value: 3)])
        await store.save(backup(ConnectionRig.cameraName, 2, "FIRST", at: 0))
        await store.save(wanted)
        await store.save(backup(ConnectionRig.cameraName, 2, "LAST", at: 2))

        let model = BackupsModel(store: store, workflow: rig.workflow)
        await model.load()
        let entry = try #require(model.histories.first?.entries[1])
        #expect(entry.backup.slotName == "MIDDLE")
        await model.restore(entry.backup)
        #expect(model.message == "C2 restored.")
        #expect(try await rig.device.getString(TestSupport.propSlotName) == "MIDDLE")
        #expect(try await rig.device.getInt(TestSupport.code("Sharpness")) == 3)
        #expect(model.histories.first?.entries.count == 4, "the restore's own backup joined the history")
        #expect(model.histories.first?.original.backup.slotName == "FIRST")
    }

    @Test func restoreOriginalsIgnoresAnotherCamerasBackups() async throws {
        let store = InMemoryBackupStore()
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0)
        await store.save(backup("X-S10", 1, "S10 ORIGINAL", at: 0))
        await store.save(backup(ConnectionRig.cameraName, 1, "T50 ORIGINAL", at: 1))
        await store.save(backup(ConnectionRig.cameraName, 1, "T50 later", at: 2))

        let model = BackupsModel(store: store, workflow: rig.workflow)
        await model.load()
        await model.restoreOriginals()
        #expect(await rig.nameWrites == ["T50 ORIGINAL"])
        #expect(model.message == "Restored the originals of 1 slot.")
    }

    @Test func nothingToRestoreIsSaidInWords() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.load()
        #expect(!model.canRestoreOriginals)
        await model.requestRestoreOriginals()
        #expect(model.restoreOriginalsPrompt == nil)
        #expect(model.message == "There are no original backups to restore.")
        #expect(await rig.device.writes.isEmpty)
    }

    @Test func withoutACameraRestoreOriginalsSaysSoAndWritesNothing() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        try await pushCollection(rig)
        let model = BackupsModel(store: rig.store, workflow: rig.workflow)
        await model.load()
        await rig.transport.unplug()
        await eventually { await rig.rig.connection.current == .lost(.disconnected) }
        let writes = await rig.device.writes.count

        await model.requestRestoreOriginals()
        #expect(model.message == "No camera is connected.")
        await model.restoreOriginals()
        #expect(model.message == "No camera is connected.")
        #expect(await rig.device.writes.count == writes)
    }

    @Test func aPartialRestoreNamesWhatDidNotTake() async throws {
        let sharpness = TestSupport.code("Sharpness")
        let store = InMemoryBackupStore()
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0, setRejectionCodes: [sharpness: 0x2005])
        await store.save(SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 4, capturedAt: Date(), slotName: "KEEP",
            properties: [BackupProperty(name: "Sharpness", code: sharpness, value: 1)]))
        let model = BackupsModel(store: store, workflow: rig.workflow)
        await model.load()
        await model.restoreOriginals()
        #expect(model.message == "Restored the originals of 1 slot. C4: Sharpness not restored.")
        #expect(model.successCount == 0)
    }
}

@MainActor
@Suite("Restore takes a backup first")
struct RestoreBacksUpFirstTests {
    @Test func theCurrentContentsAreStoredBeforeAnythingIsWritten() async throws {
        let store = InMemoryBackupStore()
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0)
        let target = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 3, capturedAt: Date(), slotName: "TARGET",
            properties: [BackupProperty(name: "Sharpness", code: TestSupport.code("Sharpness"), value: 2)])

        #expect(try await rig.workflow.restore(target) == .verified)

        let stored = try #require(await store.latest(slot: 3, camera: ConnectionRig.cameraName))
        #expect(stored.slotName == WorkflowRig.originalName, "what the slot held before the restore")
        #expect(stored.id != target.id)
        let events = await rig.device.events
        let firstWrite = try #require(events.firstIndex { event in
            switch event {
            case .setInt, .setString: return true
            case .setUInt16(let code, _): return code != TestSupport.propSlotCursor
            default: return false
            }
        })
        let readsBefore = events[..<firstWrite].filter {
            if case .getInt = $0 { return true }
            if case .getString = $0 { return true }
            return false
        }
        #expect(readsBefore.count == 1 + TestSupport.encodings.writeOrder.count, "the slot was read in full first")
        #expect(await rig.nameWrites == ["TARGET"])
    }

    @Test func aRestoreWhoseBackupCannotBeStoredLeavesTheSlotAlone() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore(), interSlotDelay: 0)
        let target = SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 3, capturedAt: Date(), slotName: "TARGET",
            properties: [])
        await #expect(throws: SlotBackupError.self) { try await rig.workflow.restore(target) }
        #expect(await rig.propertyWrites.isEmpty)
        #expect(await rig.nameWrites.isEmpty)
    }

    @Test func undoThisPushStillRestoresOnlyTheRunAndOriginalsReachesFurther() async throws {
        let store = InMemoryBackupStore()
        await store.save(backup(ConnectionRig.cameraName, 1, "ANCIENT", at: 0))
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0)
        let recipes = try WorkflowRig.recipes(2)
        let items = (1...2).map { CollectionPushModel.Item(id: $0, name: "R\($0)") }
        let model = CollectionPushModel(
            items: items, recipes: recipes, slotCount: 7, workflow: rig.workflow, clock: rig.collectionClock)
        await model.start()
        #expect(model.canRestoreAll)
        #expect(model.canRestoreOriginals)
        #expect(model.undoPushLabel == "Undo this push")
        #expect(model.restoreOriginalsLabel == "Restore originals")

        await model.restoreAll()
        #expect(model.phase == .restored([1: .verified, 2: .verified]))
        let names = await rig.nameWrites
        // Written back from this run's own backups (C1 as the camera had it, C2 as C1's push left it).
        #expect(names == ["R1", "R2", WorkflowRig.originalName, "R1"])
        #expect(!names.contains("ANCIENT"))
    }

    @Test func collectionPushRestoreOriginalsReachesBackBeforeTheRun() async throws {
        let store = InMemoryBackupStore()
        await store.save(backup(ConnectionRig.cameraName, 1, "ANCIENT", at: 0))
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0)
        let recipes = try WorkflowRig.recipes(2)
        let items = (1...2).map { CollectionPushModel.Item(id: $0, name: "R\($0)") }
        let model = CollectionPushModel(
            items: items, recipes: recipes, slotCount: 7, workflow: rig.workflow, clock: rig.collectionClock)
        #expect(!model.canRestoreOriginals)
        await model.start()

        await model.requestRestoreOriginals()
        let prompt = try #require(model.restoreOriginalsPrompt)
        #expect(prompt.contains("C1 ANCIENT"))
        #expect(prompt.contains("C2 R1"), "the run's first backup of C2")

        await model.restoreOriginals()
        #expect(model.restoreOriginalsPrompt == nil)
        #expect(model.phase == .restored([1: .verified, 2: .verified]))
        #expect(await rig.nameWrites.suffix(2) == ["ANCIENT", "R1"])
        #expect(!model.canRestoreAll)
    }
}
