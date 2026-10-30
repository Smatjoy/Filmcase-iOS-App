import Foundation
import Testing
@testable import FilmcaseKit

/// `Array.move(fromOffsets:toOffset:)` is SwiftUI-only, so this is the documented behaviour
/// written a different way: the rows at *source* go, in order, before the row that was at
/// *destination*; everything else keeps its order.
private func reference<T>(_ rows: [T], from source: IndexSet, to destination: Int) -> [T] {
    let moving = source.map { rows[$0] }
    var rest: [T] = []
    var insertion: Int?
    for (offset, row) in rows.enumerated() {
        if offset == destination { insertion = rest.count }
        if !source.contains(offset) { rest.append(row) }
    }
    let at = insertion ?? rest.count
    return Array(rest[..<at]) + moving + Array(rest[at...])
}

@MainActor
@Suite("CollectionPushModel rows")
struct CollectionPushMoveRowsTests {
    private func model(_ rig: WorkflowRig, count: Int = 3, slotCount: Int = 7) throws -> CollectionPushModel {
        let items = (1...count).map { CollectionPushModel.Item(id: $0, name: "R\($0)") }
        return CollectionPushModel(
            items: items, recipes: try WorkflowRig.recipes(count), slotCount: slotCount,
            workflow: rig.workflow, clock: rig.collectionClock)
    }

    private func ids(_ model: CollectionPushModel) -> [RecipeID?] { model.rows.map { $0.item?.id } }

    @Test func movingARowDownShiftsTheRowsInBetweenInsteadOfSwapping() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.moveRows(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(ids(model) == [2, 3, 1, nil, nil, nil, nil])
        #expect(model.assignment == [1: 2, 2: 3, 3: 1])
    }

    @Test func movingARowUpShiftsToo() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.moveRows(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(ids(model) == [3, 1, 2, nil, nil, nil, nil])
    }

    @Test func aRowCanGoToTheEndAndEmptySlotsMoveToo() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.moveRows(fromOffsets: IndexSet(integer: 0), toOffset: 7)
        #expect(ids(model) == [2, 3, nil, nil, nil, nil, 1])
        model.moveRows(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(ids(model) == [nil, 2, 3, nil, nil, nil, 1])
    }

    @Test func movingARowOntoItselfOrNextToItselfChangesNothing() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        let before = ids(model)
        model.moveRows(fromOffsets: IndexSet(integer: 1), toOffset: 1)
        model.moveRows(fromOffsets: IndexSet(integer: 1), toOffset: 2)
        #expect(ids(model) == before)
    }

    @Test func severalRowsMoveTogetherKeepingTheirOrder() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        model.moveRows(fromOffsets: IndexSet([0, 2]), toOffset: 6)
        #expect(ids(model) == [2, nil, nil, nil, 1, 3, nil])
    }

    @Test func everyMoveOfEverySetOfRowsMatchesListOnMove() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0), count: 4)
        let start = ids(model)
        for mask in 1..<(1 << 7) {
            let source = IndexSet((0..<7).filter { mask & (1 << $0) != 0 })
            for destination in 0...7 {
                model.clearAll()
                model.autoFill()
                model.moveRows(fromOffsets: source, toOffset: destination)
                #expect(
                    ids(model) == reference(start, from: source, to: destination),
                    "move \(Array(source)) to \(destination)")
            }
        }
    }

    @Test func aMoveKeepsEveryRecipeAndRenumbersTheSlots() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0), count: 9)
        model.moveRows(fromOffsets: IndexSet([1, 5]), toOffset: 0)
        #expect(Set(model.assignment.values) == Set(1...7))
        #expect(model.rows.map(\.slot) == Array(1...7))
        #expect(model.unassignedItems.map(\.id) == [8, 9])
    }

    @Test func offsetsOutsideTheListAreIgnored() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        let before = model.assignment
        model.moveRows(fromOffsets: IndexSet(integer: 7), toOffset: 0)
        model.moveRows(fromOffsets: IndexSet(integer: -1), toOffset: 0)
        model.moveRows(fromOffsets: IndexSet(integer: 0), toOffset: 8)
        model.moveRows(fromOffsets: IndexSet(integer: 0), toOffset: -1)
        model.moveRows(fromOffsets: IndexSet(), toOffset: 3)
        #expect(model.assignment == before)
    }

    @Test func aCameraWithoutSlotsHasNothingToMove() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0), slotCount: 0)
        model.moveRows(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(model.assignment.isEmpty)
    }

    // --- row and status text ---

    @Test func rowsNameTheirContentOrCallThemEmpty() async throws {
        let model = try model(try await WorkflowRig(interSlotDelay: 0))
        #expect(model.rows.map(\.displayName) == ["R1", "R2", "R3", "Empty", "Empty", "Empty", "Empty"])
    }

    @Test func statusesCarryTheirOwnWords() {
        typealias Status = CollectionPushModel.SlotStatus
        #expect(Status.waiting.displayText == nil)
        #expect(Status.waiting.accessibilityText == nil)
        #expect(Status.waiting.indicator == .none)

        #expect(Status.pushing.displayText == "Pushing")
        #expect(Status.pushing.accessibilityText == "Pushing")
        #expect(Status.pushing.indicator == .progress)

        let verified = Status.done(.verified)
        #expect(verified.displayText == "Verified")
        #expect(verified.accessibilityText == "Verified")
        #expect(verified.indicator == .success)

        let partial = Status.done(.partiallyFailed(["HighLightTone", "Sharpness"]))
        #expect(partial.displayText == "2 settings not applied")
        #expect(partial.accessibilityText == "Did not take: High Light Tone, Sharpness")
        #expect(partial.indicator == .warning)
        #expect(Status.done(.partiallyFailed(["Sharpness"])).displayText == "1 setting not applied")

        let lost = Status.done(.connectionLost)
        #expect(lost.displayText == "Not pushed \u{2014} connection lost")
        #expect(lost.accessibilityText == "Not pushed, connection lost")
        #expect(lost.indicator == .failure)
    }

    @Test func aResultHasTheSameWordsOutsideAStatus() {
        let result = SlotPushResult.partiallyFailed(["Sharpness"])
        #expect(result.displayText == "1 setting not applied")
        #expect(result.accessibilityText == "Did not take: Sharpness")
        #expect(result.indicator == .warning)
    }
}
