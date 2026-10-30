// CollectionPush: validation before any write, slot ordering, inter-slot waits, progress,
// partial failures, and stopping and resuming after the connection is lost.

import Foundation
import Testing
@testable import FilmcaseKit

private let delay = 0.044   // CAMERA_INTER_SLOT_DELAY_S in push_vectors.json
private let everySlot: [SlotIndex: RecipeID] = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, $0) })

/// Consume a run's progress, releasing each inter-slot wait on the collection clock as it
/// is requested. `beforeRelease` runs when a slot finishes, before the next one is released.
private func drain(
    _ run: CollectionPushRun, clock: TestClock,
    beforeRelease: (CollectionPushProgress) async -> Void = { _ in }
) async -> [CollectionPushProgress] {
    let baseline = clock.sleeps.count
    var seen: [CollectionPushProgress] = []
    var pump: Task<Void, Never>?
    for await progress in run.progress {
        pump?.cancel()
        pump = nil
        seen.append(progress)
        guard case .finished(let result) = progress.phase else { continue }
        await beforeRelease(progress)
        if result != .connectionLost, progress.completed < progress.total {
            // Advance until the wait ends (the next progress event). Repeated, because
            // TestClock records a sleep a moment before the sleeper is registered, so a
            // single advance can land too early and be lost.
            let requested = baseline + progress.completed
            pump = Task {
                while !Task.isCancelled {
                    if clock.sleeps.count >= requested { clock.advance(by: .seconds(delay)) }
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
        }
    }
    pump?.cancel()
    return seen
}

@Suite("CollectionPush")
struct CollectionPushTests {
    private func collection(_ rig: WorkflowRig) -> CollectionPush {
        CollectionPush(workflow: rig.workflow, clock: rig.collectionClock)
    }

    // --- validation ---

    @Test func anAssignmentFromPairsRejectsADuplicateSlot() {
        #expect(throws: CollectionPushError.duplicateSlot(2)) {
            try CollectionPush.assignment(from: [(1, 10), (2, 11), (2, 12)])
        }
        #expect(throws: Never.self) {
            try CollectionPush.assignment(from: [(1, 10), (2, 10)])
        }
    }

    @Test(arguments: [
        ([SlotIndex: RecipeID](), CollectionPushError.emptyAssignment),
        ([8: 1], CollectionPushError.slotOutOfRange(slot: 8, slotCount: 7)),
        ([0: 1], CollectionPushError.slotOutOfRange(slot: 0, slotCount: 7)),
        ([1: 99], CollectionPushError.unknownRecipe(99)),
    ])
    func aBadAssignmentIsRejectedBeforeAnyWrite(
        assignment: [SlotIndex: RecipeID], expected: CollectionPushError
    ) async throws {
        let rig = try await WorkflowRig()
        await #expect(throws: expected) {
            try await collection(rig).start(recipes: WorkflowRig.recipes(3), assignment: assignment)
        }
        #expect(await rig.device.events.isEmpty)
    }

    @Test func aRecipeTheCameraCannotTakeIsRejectedBeforeTheFirstSlotIsTouched() async throws {
        let rig = try await WorkflowRig()
        var recipes = try WorkflowRig.recipes(3)
        recipes[3]?.filmSimulation = "Not A Film Simulation"
        do {
            _ = try await collection(rig).start(recipes: recipes, assignment: [1: 1, 2: 2, 3: 3])
            Issue.record("expected invalidRecipe")
        } catch CollectionPushError.invalidRecipe(let badSlot, _) {
            #expect(badSlot == 3)
        }
        #expect(await rig.device.events.isEmpty, "slots 1 and 2 were not written either")
    }

    @Test func nothingToPushWhileDisconnected() async throws {
        let rig = try await WorkflowRig()
        await rig.rig.connection.disconnect()
        await #expect(throws: CollectionPushError.notConnected) {
            try await collection(rig).start(recipes: WorkflowRig.recipes(1), assignment: [1: 1])
        }
    }

    // --- running ---

    @Test func slotsArePushedInSlotOrderWhateverTheAssignmentOrder() async throws {
        let rig = try await WorkflowRig()
        let recipes = try WorkflowRig.recipes(3)
        let run = try await collection(rig).start(recipes: recipes, assignment: [3: 1, 1: 3, 2: 2])
        _ = await drain(run, clock: rig.collectionClock)
        let report = try await run.report

        #expect(await rig.nameWrites == ["R3", "R2", "R1"], "slot 1 got R3, slot 2 R2, slot 3 R1")
        #expect(report.done == [1, 2, 3])
        #expect(report.isComplete)
        #expect(report.results.values.allSatisfy { $0 == .verified })
        #expect(try await rig.store.all().count == 3, "one backup per slot")
    }

    @Test func theServedInterSlotDelayIsWaitedBetweenSlotsOnly() async throws {
        let rig = try await WorkflowRig()
        let run = try await collection(rig).start(recipes: WorkflowRig.recipes(7), assignment: everySlot)
        _ = await drain(run, clock: rig.collectionClock)
        _ = try await run.report
        #expect(rig.collectionClock.sleeps == Array(repeating: .seconds(delay), count: 6))
    }

    @Test func noDelayIsWaitedWhenTheServerSaysZero() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let run = try await collection(rig).start(recipes: WorkflowRig.recipes(3), assignment: [1: 1, 2: 2, 3: 3])
        for await _ in run.progress {}
        _ = try await run.report
        #expect(rig.collectionClock.sleeps.isEmpty)
    }

    @Test func progressReportsEachSlotStartingAndFinishing() async throws {
        let rig = try await WorkflowRig()
        let run = try await collection(rig).start(recipes: WorkflowRig.recipes(3), assignment: [1: 1, 3: 2])
        let progress = await drain(run, clock: rig.collectionClock)
        #expect(progress == [
            .init(slot: 1, recipeID: 1, phase: .started, completed: 0, total: 2),
            .init(slot: 1, recipeID: 1, phase: .finished(.verified), completed: 1, total: 2),
            .init(slot: 3, recipeID: 2, phase: .started, completed: 1, total: 2),
            .init(slot: 3, recipeID: 2, phase: .finished(.verified), completed: 2, total: 2),
        ])
    }

    @Test func aPartiallyFailedSlotIsReportedAndTheRunCarriesOn() async throws {
        let rig = try await WorkflowRig(setRejectionCodes: [TestSupport.code("Sharpness"): 0x2005])
        let run = try await collection(rig).start(recipes: WorkflowRig.recipes(7), assignment: everySlot)
        _ = await drain(run, clock: rig.collectionClock)
        let report = try await run.report

        #expect(report.done == Array(1...7))
        #expect(report.isComplete)
        #expect(report.failedSlots == Array(1...7))
        #expect(report.results[4] == .partiallyFailed(["Sharpness"]))
    }

    // --- the connection is lost ---

    @Test func lostAtSlotFourReportsWhatIsDoneAndWhatRemains() async throws {
        let rig = try await WorkflowRig()
        let run = try await collection(rig).start(recipes: WorkflowRig.recipes(7), assignment: everySlot)
        _ = await drain(run, clock: rig.collectionClock) { progress in
            if progress.slot == 3 {
                await rig.transport.unplug()
                await waitUntil { await rig.rig.connection.current == .lost(.disconnected) }
            }
        }
        let report = try await run.report

        #expect(report.done == [1, 2, 3])
        #expect(report.remaining == [4, 5, 6, 7])
        #expect(report.results[4] == .connectionLost)
        #expect(!report.isComplete)
        #expect(await rig.nameWrites == ["R1", "R2", "R3"], "nothing was written after the loss")
    }

    @Test func resumePushesOnlyTheRemainingSlots() async throws {
        let rig = try await WorkflowRig()
        let recipes = try WorkflowRig.recipes(7)
        let first = try await collection(rig).start(recipes: recipes, assignment: everySlot)
        _ = await drain(first, clock: rig.collectionClock) { progress in
            if progress.slot == 3 {
                await rig.transport.unplug()
                await waitUntil { await rig.rig.connection.current == .lost(.disconnected) }
            }
        }
        let lost = try await first.report

        await rig.transport.plugIn()
        await waitUntil { await rig.rig.connection.current == .ready(cameraName: ConnectionRig.cameraName) }

        let resumed = try await collection(rig).resume(from: lost, recipes: recipes)
        let progress = await drain(resumed, clock: rig.collectionClock)
        let report = try await resumed.report

        #expect(progress.filter { $0.phase == .started }.map(\.slot) == [4, 5, 6, 7])
        #expect(report.done == Array(1...7))
        #expect(report.isComplete)
        #expect(report.results.values.allSatisfy { $0 == .verified })
        #expect(await rig.nameWrites == (1...7).map { "R\($0)" }, "each recipe written exactly once")
    }

    @Test func aBackupThatCannotBeSavedStopsTheRunWithAReport() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore())
        let run = try await collection(rig).start(recipes: WorkflowRig.recipes(3), assignment: [1: 1, 2: 2, 3: 3])
        for await _ in run.progress {}
        do {
            _ = try await run.report
            Issue.record("expected the run to stop")
        } catch CollectionPushError.stopped(let report, _) {
            #expect(report.done.isEmpty)
            #expect(report.remaining == [1, 2, 3])
        }
        #expect(await rig.propertyWrites.isEmpty)
    }
}
