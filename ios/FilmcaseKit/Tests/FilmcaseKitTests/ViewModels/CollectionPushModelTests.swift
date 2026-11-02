import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

/// Advance *clock* until cancelled, so inter-slot waits end.
private func pump(_ clock: TestClock) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            clock.advance(by: .seconds(1))
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
@Suite("CollectionPushModel")
struct CollectionPushModelTests {
    private func model(
        _ rig: WorkflowRig, count: Int = 3, slotCount: Int = 7,
        tweak: (inout [RecipeID: Recipe]) -> Void = { _ in }
    ) throws -> CollectionPushModel {
        var recipes = try WorkflowRig.recipes(count)
        tweak(&recipes)
        let items = (1...count).map { CollectionPushModel.Item(id: $0, name: "R\($0)") }
        return CollectionPushModel(
            items: items, recipes: recipes, slotCount: slotCount, workflow: rig.workflow, clock: rig.collectionClock)
    }

    // --- editing the assignment ---

    @Test func startsWithTheRecipesFilledInOrder() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        #expect(model.assignment == [1: 1, 2: 2, 3: 3])
        #expect(model.rows.count == 7)
        #expect(model.rows.map { $0.item?.name } == ["R1", "R2", "R3", nil, nil, nil, nil])
        #expect(model.rows[0].title == "C1")
        #expect(model.unassignedItems.isEmpty)
        #expect(model.canStart)
    }

    @Test func moreRecipesThanSlotsLeavesTheRestUnassigned() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let model = try model(rig, count: 9)
        #expect(model.assignment.count == 7)
        #expect(model.unassignedItems.map(\.id) == [8, 9])
    }

    @Test func assigningARecipeMovesItOutOfItsOldSlot() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.assign(1, to: 5)
        #expect(model.assignment == [2: 2, 3: 3, 5: 1])
    }

    @Test func assigningOntoAnOccupiedSlotSwaps() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.assign(1, to: 3)
        #expect(model.assignment == [1: 3, 2: 2, 3: 1])
    }

    @Test func aRecipeFromTheUnassignedPileDisplacesTheOccupant() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0), count: 9)
        model.assign(8, to: 2)
        #expect(model.assignment[2] == 8)
        #expect(model.unassignedItems.map(\.id) == [2, 9], "recipe 2 was bumped out")
    }

    @Test func outOfRangeAndUnknownAssignmentsAreIgnored() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.assign(1, to: 8)
        model.assign(1, to: 0)
        model.assign(99, to: 4)
        #expect(model.assignment == [1: 1, 2: 2, 3: 3])
    }

    @Test func clearingASlotAndClearingEverything() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.clear(slot: 2)
        #expect(model.assignment == [1: 1, 3: 3])
        #expect(model.unassignedItems.map(\.id) == [2])
        model.clearAll()
        #expect(model.assignment.isEmpty)
        model.autoFill()
        #expect(model.assignment == [1: 1, 2: 2, 3: 3])
    }

    // --- validation ---

    @Test func anEmptyAssignmentCannotStart() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.clearAll()
        #expect(model.validationMessages == ["Assign at least one recipe to a slot."])
        #expect(!model.canStart)
        await model.start()
        #expect(model.phase == .editing)
    }

    @Test func aRecipeTheCameraCannotTakeIsNamedWithItsSlot() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let model = try model(rig) { $0[2]?.filmSimulation = "Not A Film" }
        #expect(model.validationMessages.count == 1)
        #expect(model.validationMessages.first?.hasPrefix("C2, R2: ") == true)
        #expect(!model.canStart)
        await model.start()
        #expect(model.phase == .editing)
        #expect(await rig.propertyWrites.isEmpty)

        model.clear(slot: 2)
        #expect(model.validationMessages.isEmpty)
    }

    @Test func aCameraWithoutSlotsCannotStart() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0), slotCount: 0)
        #expect(model.rows.isEmpty)
        #expect(model.validationMessages == ["The camera has no custom slots."])
    }

    @Test func startingWithoutACameraSaysSoAndStaysEditable() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let model = try model(rig)
        await rig.transport.unplug()
        await eventually { await rig.rig.connection.current == .lost(.disconnected) }

        await model.start()
        #expect(model.phase == .editing)
        #expect(model.errorMessage == "No camera is connected.")
        #expect(model.statuses.isEmpty || model.statuses.values.allSatisfy { $0 == .waiting })
    }

    // --- running ---

    @Test func aFullRunVerifiesEverySlotWithProgress() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let model = try model(rig)
        await model.start()

        guard case .finished(let report) = model.phase else { Issue.record("not finished: \(model.phase)"); return }
        #expect(report.done == [1, 2, 3])
        #expect(model.statuses == [1: .done(.verified), 2: .done(.verified), 3: .done(.verified)])
        #expect(model.completed == 3)
        #expect(model.total == 3)
        #expect(await rig.nameWrites == ["R1", "R2", "R3"])
        #expect(model.canRestoreAll)
        #expect(!model.canStart, "it has run; arrange again to start another")
    }

    @Test func aPartiallyFailedSlotIsShownAndTheRunCarriesOn() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0, setRejectionCodes: [TestSupport.code("Sharpness"): 0x2005])
        let model = try model(rig)
        await model.start()

        guard case .finished(let report) = model.phase else { Issue.record("not finished"); return }
        #expect(report.failedSlots == [1, 2, 3])
        #expect(model.statuses[2] == .done(.partiallyFailed(["Sharpness"])))
    }

    @Test func aBackupThatCannotBeStoredInterruptsTheRunWithAMessage() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore(), interSlotDelay: 0)
        let model = try model(rig)
        await model.start()

        guard case .interrupted(let report, let message) = model.phase else { Issue.record("not interrupted"); return }
        #expect(report.done.isEmpty)
        #expect(message?.hasPrefix("The push stopped:") == true)
        #expect(model.canResume)
        #expect(await rig.propertyWrites.isEmpty)
    }

    @Test func editAgainAfterARunReturnsToArranging() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        await model.start()
        model.editAgain()
        #expect(model.phase == .editing)
        #expect(model.statuses.isEmpty)
        #expect(model.completed == 0)
        #expect(model.canStart)
    }

    // --- connection lost, resume, restore ---

    /// Run until slot 1 is done and the run waits for the next slot, then unplug.
    private func runUntilLost(_ rig: WorkflowRig, _ model: CollectionPushModel) async {
        let running = Task { await model.start() }
        await rig.collectionClock.waitForSleeps(1)
        await rig.transport.unplug()
        await eventually { await rig.rig.connection.current == .lost(.disconnected) }
        let pumping = pump(rig.collectionClock)
        await running.value
        pumping.cancel()
    }

    @Test func lostMidRunReportsWhatIsDoneAndWhatRemains() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0.044)
        let model = try model(rig, count: 4)
        await runUntilLost(rig, model)

        guard case .interrupted(let report, let message) = model.phase else { Issue.record("not interrupted: \(model.phase)"); return }
        #expect(report.done == [1])
        #expect(report.remaining == [2, 3, 4])
        #expect(message == "The camera connection was lost.")
        #expect(model.statuses[1] == .done(.verified))
        #expect(model.statuses[2] == .waiting)
        #expect(model.completed == 1)
        #expect(model.canResume)
        #expect(await rig.nameWrites == ["R1"], "nothing was written after the loss")
    }

    @Test func resumingPushesOnlyTheRest() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0.044)
        let model = try model(rig, count: 4)
        await runUntilLost(rig, model)

        await rig.transport.plugIn()
        await eventually { await rig.rig.connection.current == .ready(cameraName: ConnectionRig.cameraName) }
        let pumping = pump(rig.collectionClock)
        await model.resume()
        pumping.cancel()

        guard case .finished(let report) = model.phase else { Issue.record("not finished: \(model.phase)"); return }
        #expect(report.done == [1, 2, 3, 4])
        #expect(model.statuses.values.allSatisfy { $0 == .done(.verified) })
        #expect(model.completed == 4)
        #expect(await rig.nameWrites == ["R1", "R2", "R3", "R4"], "each recipe was written exactly once")
    }

    @Test func resumingWithoutTheCameraKeepsTheRunInterrupted() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0.044)
        let model = try model(rig, count: 3)
        await runUntilLost(rig, model)

        await model.resume()
        guard case .interrupted(_, let message) = model.phase else { Issue.record("not interrupted"); return }
        #expect(message == "No camera is connected.")
    }

    @Test func restoreAllPutsEverySlotBack() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let model = try model(rig)
        await model.start()
        await model.restoreAll()

        #expect(model.phase == .restored([1: .verified, 2: .verified, 3: .verified]))
        // The fake camera keeps one value per property, not per slot, so the backups of slots
        // 2 and 3 hold what the earlier pushes wrote. What matters: each slot is written back
        // from its own backup, in slot order, after the pushes.
        #expect(await rig.nameWrites == ["R1", "R2", "R3", WorkflowRig.originalName, "R1", "R2"])
    }

    @Test func restoreAllAfterAnInterruptedRunRestoresOnlyWhatWasWritten() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0.044)
        let model = try model(rig, count: 3)
        await runUntilLost(rig, model)
        await rig.transport.plugIn()
        await eventually { await rig.rig.connection.current == .ready(cameraName: ConnectionRig.cameraName) }

        await model.restoreAll()
        #expect(model.phase == .restored([1: .verified]))
        // The run's backup of C1, plus the one the restore took of C1 before writing.
        #expect(try await rig.store.all().count == 2)
    }

    @Test func restoreAllIsNotOfferedBeforeARun() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        #expect(!model.canRestoreAll)
        await model.restoreAll()
        #expect(model.phase == .editing)
    }

    @Test func restoreAllIgnoresBackupsFromEarlierRuns() async throws {
        let store = InMemoryBackupStore()
        await store.save(SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: 1, capturedAt: Date(timeIntervalSince1970: 1),
            slotName: "ANCIENT", properties: []))
        let rig = try await WorkflowRig(store: store, interSlotDelay: 0)
        let model = try model(rig)
        await model.start()
        await model.restoreAll()
        let names = await rig.nameWrites
        #expect(names.dropFirst(3).first == WorkflowRig.originalName, "slot 1 came back from this run's backup")
        #expect(!names.contains("ANCIENT"))
    }

    // --- building from a collection ---

    @Test func loadsEveryRecipesCameraDataInCollectionOrder() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let server = ModelRig(script: { request in
            request.isAuthenticated ? .fixture("camera_payload") : .fixture("recipe_list")
        })
        let detail = try Fixture.decode(CollectionDetail.self, "collection_detail")
        let model = try await CollectionPushModel.load(
            collection: detail, client: server.client, workflow: rig.workflow, clock: rig.collectionClock)

        #expect(model.items.map(\.name) == ["Kodak Portra", "Plain Provia"])
        #expect(model.slotCount == 7)
        #expect(model.assignment == [1: 1, 2: 2])
        #expect(model.canStart)
    }

    @Test func aCameraPayloadThatFailsToLoadFailsTheBuild() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let server = ModelRig(script: { request in
            request.isAuthenticated ? .fixture("error_404", status: 404) : .fixture("recipe_list")
        })
        let detail = try Fixture.decode(CollectionDetail.self, "collection_detail")
        await #expect(throws: FilmcaseClientError.self) {
            try await CollectionPushModel.load(collection: detail, client: server.client, workflow: rig.workflow)
        }
    }
}
