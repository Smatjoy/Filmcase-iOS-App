import Foundation
import Testing
@testable import FilmcaseKit

@MainActor
@Suite("PushSheetModel")
struct PushSheetModelTests {
    private let slots = (1...7).map { SlotItem(index: $0, name: "Slot \($0)", filmSimName: "Provia") }
    private let slot = 3

    private func model(_ rig: WorkflowRig) throws -> PushSheetModel {
        PushSheetModel(recipe: try TestSupport.makeRecipe(), slots: slots, workflow: rig.workflow)
    }

    private func pushed(_ model: PushSheetModel) async {
        model.choose(slot: slot)
        await model.confirm()
    }

    // --- choosing and confirming ---

    @Test func startsOnTheSlotGridAndAsksBeforeOverwriting() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        #expect(model.phase == .choosingSlot)
        #expect(model.overwriteWarning == nil)

        model.choose(slot: slot)
        #expect(model.phase == .confirming(slots[2]))
        let name = model.recipe.name
        #expect(model.overwriteWarning
            == "C3 holds \u{201C}Slot 3\u{201D}. It will be backed up, then replaced with \u{201C}\(name)\u{201D}.")
        #expect(await rig.propertyWrites.isEmpty, "choosing writes nothing")
    }

    @Test func anEmptySlotIsDescribedAsEmpty() async throws {
        let rig = try await WorkflowRig()
        let model = PushSheetModel(
            recipe: try TestSupport.makeRecipe(), slots: [SlotItem(index: 1, name: "", filmSimName: "Provia")],
            workflow: rig.workflow)
        model.choose(slot: 1)
        #expect(model.overwriteWarning?.hasPrefix("C1 is empty.") == true)
    }

    @Test func backingOutReturnsToTheGrid() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        model.choose(slot: slot)
        model.cancelConfirmation()
        #expect(model.phase == .choosingSlot)
    }

    @Test func aSlotThatDoesNotExistCannotBeChosenAndConfirmNeedsAChoice() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        model.choose(slot: 9)
        #expect(model.phase == .choosingSlot)
        await model.confirm()
        #expect(model.phase == .choosingSlot)
        #expect(await rig.device.events.isEmpty)
    }

    // --- pushing ---

    @Test func aVerifiedPushOffersARestoreAndFiresSuccessFeedback() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        await pushed(model)

        #expect(model.phase == .finished(.init(action: .push, slot: slot, result: .verified)))
        #expect(model.successCount == 1)
        #expect(model.problemCount == 0)
        #expect(model.canRestore)
        #expect(model.lastBackup?.slotName == WorkflowRig.originalName)
        #expect(await rig.nameWrites == [model.recipe.name])
    }

    @Test func restoringPutsTheSlotBackAndVerifiesIt() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        await pushed(model)
        await model.restore()

        #expect(model.phase == .finished(.init(action: .restore, slot: slot, result: .verified)))
        #expect(model.successCount == 2)
        #expect(!model.canRestore, "a restored backup is spent")
        #expect(try await rig.device.getString(TestSupport.propSlotName) == WorkflowRig.originalName)
    }

    @Test func aPartialFailureNamesTheRefusedPropertiesAsADiff() async throws {
        let rig = try await WorkflowRig(setRejectionCodes: [TestSupport.code("Sharpness"): 0x2005])
        let model = try model(rig)
        await pushed(model)

        guard case .finished(let outcome) = model.phase else { Issue.record("not finished"); return }
        #expect(outcome.result == .partiallyFailed(["Sharpness"]))
        #expect(outcome.diff == [PropertyDiffRow(name: "Sharpness")])
        #expect(model.successCount == 0)
        #expect(model.problemCount == 1)
        #expect(model.canRestore, "the slot was partly overwritten, so restoring is offered")
    }

    @Test func diffRowsAreReadable() {
        #expect(PropertyDiffRow(name: "HighLightTone").label == "High Light Tone")
        #expect(PropertyDiffRow(name: "Sharpness").label == "Sharpness")
    }

    @Test func losingTheCameraBeforeTheBackupMeansNothingToRestore() async throws {
        let rig = try await WorkflowRig(unplugOnCall: 4)
        let model = try model(rig)
        await pushed(model)

        #expect(model.phase == .finished(.init(action: .push, slot: slot, result: .connectionLost)))
        #expect(model.problemCount == 1)
        #expect(!model.canRestore)
        #expect(await rig.propertyWrites.isEmpty)
    }

    @Test func anOlderBackupOfTheSlotIsNotOfferedAsThisPushesBackup() async throws {
        let store = InMemoryBackupStore()
        await store.save(SlotBackup(
            cameraName: ConnectionRig.cameraName, slotIndex: slot, capturedAt: Date(),
            slotName: "FROM LAST WEEK", properties: []))
        let rig = try await WorkflowRig(store: store, unplugOnCall: 4)
        let model = try model(rig)
        await pushed(model)
        #expect(model.phase == .finished(.init(action: .push, slot: slot, result: .connectionLost)))
        #expect(!model.canRestore)
    }

    @Test func losingTheCameraDuringThePushKeepsTheBackupButRestoringReportsTheLoss() async throws {
        // Calls: cursor, name, then one read per property make the backup; the push follows.
        let backupCalls = 2 + TestSupport.encodings.writeOrder.count
        let rig = try await WorkflowRig(unplugOnCall: backupCalls + 2)
        let model = try model(rig)
        await pushed(model)

        #expect(model.phase == .finished(.init(action: .push, slot: slot, result: .connectionLost)))
        #expect(model.canRestore)
        await model.restore()
        #expect(model.phase == .finished(.init(action: .restore, slot: slot, result: .connectionLost)))
        #expect(model.problemCount == 2)
    }

    @Test func aBackupThatCannotBeStoredRefusesThePush() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore())
        let model = try model(rig)
        await pushed(model)

        #expect(model.phase == .finished(.init(
            action: .push, slot: slot,
            result: .failed("The slot could not be backed up, so nothing was changed."))))
        #expect(!model.canRestore)
        #expect(await rig.propertyWrites.isEmpty)
    }

    @Test func aRecipeTheCameraCannotTakeIsRefusedWithAReason() async throws {
        let rig = try await WorkflowRig()
        var recipe = try TestSupport.makeRecipe()
        recipe.filmSimulation = "Not A Film"
        let model = PushSheetModel(recipe: recipe, slots: slots, workflow: rig.workflow)
        await pushed(model)

        guard case .finished(let outcome) = model.phase, case .failed(let message) = outcome.result else {
            Issue.record("expected a refusal"); return
        }
        #expect(message.contains("film_simulation"))
        #expect(await rig.device.events.isEmpty, "rejected before anything was read")
    }

    @Test func chooseAnotherReturnsToTheGridAfterAResult() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        model.chooseAnother()
        #expect(model.phase == .choosingSlot)
        await pushed(model)
        model.chooseAnother()
        #expect(model.phase == .choosingSlot)
        model.choose(slot: 4)
        #expect(model.phase == .confirming(slots[3]))
    }

    @Test func aSecondConfirmWhileFinishedDoesNothing() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        await pushed(model)
        await model.confirm()
        #expect(model.successCount == 1)
        #expect(try await rig.store.all().count == 1)
    }

    @Test func restoreWithoutAPushDoesNothing() async throws {
        let rig = try await WorkflowRig()
        let model = try model(rig)
        await model.restore()
        #expect(model.phase == .choosingSlot)
    }
}
