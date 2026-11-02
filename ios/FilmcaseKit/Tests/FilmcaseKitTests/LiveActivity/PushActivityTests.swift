import Foundation
import Testing
@testable import FilmcaseKit

private func pumpClock(_ clock: TestClock) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            clock.advance(by: .seconds(1))
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

@Suite("PushActivityContent")
struct PushActivityContentTests {
    private func sevenSlotContent(title: String = "Summer in Lisbon") -> PushActivityContent {
        let marks = (1...7).map { PushActivityContent.SlotMark(slot: $0, status: $0 < 4 ? .verified : .waiting) }
        return .collection(
            title: title, marks: marks, completed: 3, total: 7, currentName: "A recipe name", stage: .running)
    }

    @Test func aSevenSlotCollectionEncodesWellUnderTheActivityLimit() throws {
        let data = try JSONEncoder().encode(sevenSlotContent())
        #expect(data.count < 4096)
        #expect(data.count < 1024, "leave room: the adapter adds its own fields")
    }

    @Test func longTextIsCappedSoTheLimitHolds() throws {
        let long = String(repeating: "W", count: 500)
        let content = sevenSlotContent(title: long)
        #expect(content.title.count == PushActivityContent.maxTitleLength)
        #expect(content.statusLine.count <= PushActivityContent.maxLineLength)
        #expect(content.accessibilityLabel.count <= PushActivityContent.maxAccessibilityLength)
        #expect(try JSONEncoder().encode(content).count < 4096)
    }

    @Test func contentSurvivesAnEncodeDecodeRoundTrip() throws {
        let content = sevenSlotContent()
        let decoded = try JSONDecoder().decode(PushActivityContent.self, from: JSONEncoder().encode(content))
        #expect(decoded == content)
    }

    @Test func aRunningCollectionNamesTheSlotBeingWritten() {
        let marks = [
            PushActivityContent.SlotMark(slot: 1, status: .verified),
            PushActivityContent.SlotMark(slot: 2, status: .active),
        ]
        let content = PushActivityContent.collection(
            title: "Trip", marks: marks, completed: 1, total: 2, currentName: "R2", stage: .running)
        #expect(content.phase == .writing)
        #expect(content.currentSlot == 2)
        #expect(content.statusLine == "Sending R2 to C2 (1 of 2)")
        #expect(content.fractionCompleted == 0.5)
    }

    @Test func finishedStagesPickDoneOrPartial() {
        let verified = PushActivityContent.SlotMark(slot: 1, status: .verified)
        let partial = PushActivityContent.SlotMark(slot: 2, status: .partial)
        let done = PushActivityContent.collection(
            title: "T", marks: [verified], completed: 1, total: 1, currentName: nil, stage: .finished)
        #expect(done.phase == .done)
        #expect(done.suggestedDismissal == .after(seconds: 10))
        let mixed = PushActivityContent.collection(
            title: "T", marks: [verified, partial], completed: 2, total: 2, currentName: nil, stage: .finished)
        #expect(mixed.phase == .partial)
        #expect(mixed.statusLine == "1 verified, 1 need attention")
        #expect(mixed.suggestedDismissal == .default)
        #expect(mixed.currentSlot == nil)
    }

    @Test func aLostStageIsLostAndAFailureLeavesAtOnce() {
        let lost = PushActivityContent.collection(
            title: "T", marks: [], completed: 2, total: 7, currentName: nil, stage: .stopped(connectionLost: true))
        #expect(lost.phase == .lost)
        #expect(lost.statusLine == "Connection lost after 2 of 7")
        let failed = PushActivityContent.singleFailed(recipeName: "R", slot: 1, reason: "Cancelled")
        #expect(failed.phase == .failed)
        #expect(failed.suggestedDismissal == .immediate)
    }
}

@MainActor
@Suite("Push activity reporting")
struct PushActivityReportingTests {
    private let slots = (1...7).map { SlotItem(index: $0, name: "Slot \($0)", filmSimName: "Provia") }

    private func singlePush(
        _ rig: WorkflowRig, reporter: RecordingPushActivityReporter, slot: Int = 3
    ) async throws -> PushSheetModel {
        let model = PushSheetModel(
            recipe: try TestSupport.makeRecipe(), slots: slots, workflow: rig.workflow, activity: reporter)
        model.choose(slot: slot)
        await model.confirm()
        return model
    }

    // --- one recipe ---

    @Test func aVerifiedPushStartsAndEndsDone() async throws {
        let rig = try await WorkflowRig()
        let reporter = RecordingPushActivityReporter()
        let model = try await singlePush(rig, reporter: reporter)
        let name = model.recipe.name

        let events = await reporter.events
        #expect(events.count == 2)
        #expect(events.first == .start(.singleInProgress(recipeName: name, slot: 3)))
        #expect(events.first?.content.phase == .writing)
        #expect(events.last == .end(
            .singleFinished(recipeName: name, slot: 3, result: .verified), .after(seconds: 10)))
        #expect(events.last?.content.phase == .done)
        #expect(events.last?.content.slots == [.init(slot: 3, status: .verified)])
    }

    @Test func aPartialPushEndsPartialAndStaysOnScreen() async throws {
        let code = TestSupport.code("HighLightTone")
        let rig = try await WorkflowRig(setRejectionCodes: [code: 0x2002])
        let reporter = RecordingPushActivityReporter()
        _ = try await singlePush(rig, reporter: reporter)

        let events = await reporter.events
        #expect(events.map(\.content.phase) == [.writing, .partial])
        guard case .end(let content, let dismissal) = events.last else { Issue.record("no end"); return }
        #expect(dismissal == .default)
        #expect(content.slots == [.init(slot: 3, status: .partial)])
        #expect(content.accessibilityLabel.contains("High Light Tone"))
    }

    @Test func aLostConnectionEndsLost() async throws {
        let rig = try await WorkflowRig(unplugOnCall: 3)
        let reporter = RecordingPushActivityReporter()
        _ = try await singlePush(rig, reporter: reporter)

        let events = await reporter.events
        #expect(events.map(\.content.phase) == [.writing, .lost])
        #expect(events.last?.content.statusLine == "Camera connection lost")
    }

    @Test func aRefusedPushEndsFailedWithoutWriting() async throws {
        let rig = try await WorkflowRig(store: FailingBackupStore())
        let reporter = RecordingPushActivityReporter()
        _ = try await singlePush(rig, reporter: reporter)

        let events = await reporter.events
        #expect(events.map(\.content.phase) == [.writing, .failed])
        #expect(events.last?.content.statusLine == "The slot could not be backed up, so nothing was changed.")
        guard case .end(_, let dismissal) = events.last else { Issue.record("no end"); return }
        #expect(dismissal == .immediate)
    }

    @Test func aPushWithoutAReporterStillWorks() async throws {
        let rig = try await WorkflowRig()
        let model = PushSheetModel(recipe: try TestSupport.makeRecipe(), slots: slots, workflow: rig.workflow)
        model.choose(slot: 3)
        await model.confirm()
        #expect(model.phase == .finished(.init(action: .push, slot: 3, result: .verified)))
    }

    // --- a collection ---

    private func collectionModel(
        _ rig: WorkflowRig, count: Int, reporter: RecordingPushActivityReporter
    ) throws -> CollectionPushModel {
        let items = (1...count).map { CollectionPushModel.Item(id: $0, name: "R\($0)") }
        return CollectionPushModel(
            items: items, recipes: try WorkflowRig.recipes(count), slotCount: 7, workflow: rig.workflow,
            clock: rig.collectionClock, activity: reporter, activityTitle: "Summer")
    }

    @Test func aSevenSlotPushReportsEachSlotThenEnds() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let reporter = RecordingPushActivityReporter()
        let model = try collectionModel(rig, count: 7, reporter: reporter)
        await model.start()

        let events = await reporter.events
        // start, a started and a finished update for each of the 7 slots, end.
        #expect(events.count == 16)
        guard case .start(let first) = events.first else { Issue.record("no start"); return }
        #expect(first.title == "Summer")
        #expect(first.total == 7)
        #expect(first.completed == 0)
        #expect(first.slots.map(\.status) == Array(repeating: .waiting, count: 7))

        let updates = events.dropFirst().dropLast()
        #expect(updates.allSatisfy { if case .update = $0 { true } else { false } })
        #expect(updates.map(\.content.completed) == [0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7])
        let started = updates.first?.content
        #expect(started?.currentSlot == 1)
        #expect(started?.slots.first?.status == .active)
        #expect(started?.statusLine == "Sending R1 to C1 (0 of 7)")

        guard case .end(let last, let dismissal) = events.last else { Issue.record("no end"); return }
        #expect(last.phase == .done)
        #expect(last.completed == 7)
        #expect(last.slots.allSatisfy { $0.status == .verified })
        #expect(dismissal == .after(seconds: 10))
        for event in events { #expect(try JSONEncoder().encode(event.content).count < 4096) }
    }

    @Test func aLostConnectionEndsTheRunLostAndAResumeStartsAgainWhereItStopped() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0.044)
        let reporter = RecordingPushActivityReporter()
        let model = try collectionModel(rig, count: 4, reporter: reporter)

        let running = Task { await model.start() }
        await rig.collectionClock.waitForSleeps(1)
        await rig.transport.unplug()
        await eventually { await rig.rig.connection.current == .lost(.disconnected) }
        let pumping = pumpClock(rig.collectionClock)
        await running.value
        pumping.cancel()

        var events = await reporter.events
        guard case .end(let lost, let lostDismissal) = events.last else { Issue.record("no end"); return }
        #expect(lost.phase == .lost)
        #expect(lost.completed == 1)
        #expect(lost.total == 4)
        #expect(lost.slots.map(\.status) == [.verified, .waiting, .waiting, .waiting])
        #expect(lostDismissal == .default)
        #expect(events.filter { if case .start = $0 { true } else { false } }.count == 1)

        await rig.transport.plugIn()
        await eventually { await rig.rig.connection.current == .ready(cameraName: ConnectionRig.cameraName) }
        let resumePump = pumpClock(rig.collectionClock)
        await model.resume()
        resumePump.cancel()

        events = await reporter.events
        let starts = events.enumerated().filter { if case .start = $0.element { true } else { false } }
        #expect(starts.count == 2)
        let resumeStart = try #require(starts.last).element.content
        #expect(resumeStart.completed == 1, "the resume continues the count")
        #expect(resumeStart.slots.first?.status == .verified)
        guard case .end(let final, _) = events.last else { Issue.record("no end"); return }
        #expect(final.phase == .done)
        #expect(final.completed == 4)
        #expect(final.slots.allSatisfy { $0.status == .verified })
        #expect(events.filter { if case .end = $0 { true } else { false } }.count == 2)
    }

    @Test func aRunThatCannotStartReportsNothing() async throws {
        let rig = try await WorkflowRig(interSlotDelay: 0)
        let reporter = RecordingPushActivityReporter()
        let model = try collectionModel(rig, count: 2, reporter: reporter)
        model.clearAll()
        await model.start()
        #expect(await reporter.events.isEmpty)
    }
}
