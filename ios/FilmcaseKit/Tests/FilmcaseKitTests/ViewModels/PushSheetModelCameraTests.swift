import Foundation
import Testing
@testable import FilmcaseKit

@MainActor
@Suite("PushSheetModel with a camera model")
struct PushSheetModelCameraTests {
    private func make(_ rig: WorkflowRig) throws -> (PushSheetModel, CameraModel) {
        let camera = CameraModel(
            connection: rig.rig.connection, runtime: rig.workflow.runtime, autoConnect: false)
        let model = PushSheetModel(recipe: try TestSupport.makeRecipe(), camera: camera, workflow: rig.workflow)
        return (model, camera)
    }

    @Test func showsTheCameraModelsSlotsWithoutBeingTold() async throws {
        let rig = try await WorkflowRig()
        let (model, camera) = try make(rig)
        #expect(model.slots.isEmpty)
        #expect(model.slotsState == .idle)

        await camera.refreshSlots()
        #expect(model.slots.count == 7)
        #expect(model.slots == camera.slots)
        #expect(model.slotsState == .loaded)
    }

    @Test func observingConnectsAndReadsTheSlotsWithNoTap() async throws {
        let rig = try ConnectionRig()
        let runtime = try TestSupport.runtime(rig.device)
        let camera = CameraModel(connection: rig.connection, runtime: runtime)
        let model = PushSheetModel(
            recipe: try TestSupport.makeRecipe(), camera: camera,
            workflow: SlotBackupWorkflow(
                runner: rig.connection, store: InMemoryBackupStore(), runtime: runtime, clock: TestClock()))
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await eventually { model.slotsState == .loaded }
        #expect(model.slots.count == 7)
        await eventually { model.pill?.isReady == true }
        #expect(model.pill?.isReady == true)
    }

    @Test func withoutACameraModelThereIsNoPillAndTheSlotsAreTheOnesGiven() async throws {
        let rig = try await WorkflowRig()
        let slots = [SlotItem(index: 1, name: "A", filmSimName: "Provia")]
        let model = PushSheetModel(recipe: try TestSupport.makeRecipe(), slots: slots, workflow: rig.workflow)
        #expect(model.pill == nil)
        #expect(model.slotsState == .loaded)
        await model.observe()
        await model.refreshSlots()
        #expect(model.slots == slots)
        let other = [SlotItem(index: 2, name: "B", filmSimName: "Velvia")]
        model.updateSlots(other)
        #expect(model.slots == other)
    }

    @Test func aVerifiedPushReadsTheSlotsAgainOnItsOwn() async throws {
        let rig = try await WorkflowRig()
        let (model, camera) = try make(rig)
        await camera.refreshSlots()
        #expect(model.slots.allSatisfy { $0.name == WorkflowRig.originalName })

        model.choose(slot: 3)
        await model.confirm()
        #expect(model.phase == .finished(.init(action: .push, slot: 3, result: .verified)))
        #expect(model.slots.allSatisfy { $0.name == model.recipe.name }, "the sheet re-read the camera")
    }

    @Test func aRestoreReadsTheSlotsAgainToo() async throws {
        let rig = try await WorkflowRig()
        let (model, camera) = try make(rig)
        await camera.refreshSlots()
        model.choose(slot: 3)
        await model.confirm()
        await model.restore()
        #expect(model.phase == .finished(.init(action: .restore, slot: 3, result: .verified)))
        #expect(model.slots.allSatisfy { $0.name == WorkflowRig.originalName })
    }

    @Test func aLostConnectionDoesNotTryToReadTheSlotsAgain() async throws {
        let rig = try await WorkflowRig()
        let (model, camera) = try make(rig)
        await camera.refreshSlots()
        // The camera goes away on the push's first call; a refresh afterwards would only fail.
        await rig.transport.unplug(onCall: await rig.transport.callCount + 1)
        let slotsBefore = model.slots
        model.choose(slot: 3)
        await model.confirm()
        guard case .finished(let outcome) = model.phase else { Issue.record("not finished"); return }
        #expect(outcome.result == .connectionLost)
        #expect(model.slots == slotsBefore)
        #expect(camera.errorMessage == nil)
    }

    @Test func outcomesCarryTheirHeadline() {
        typealias Outcome = PushSheetModel.Outcome
        #expect(Outcome(action: .push, slot: 3, result: .verified).message == "C3 verified")
        #expect(Outcome(action: .restore, slot: 3, result: .verified).message == "C3 restored")
        #expect(
            Outcome(action: .push, slot: 2, result: .partiallyFailed(["A", "B"])).message
                == "C2: 2 settings not applied")
        #expect(
            Outcome(action: .push, slot: 2, result: .connectionLost).message
                == "The camera connection was lost")
        #expect(Outcome(action: .push, slot: 2, result: .failed("Nope.")).message == "Nope.")
    }
}
