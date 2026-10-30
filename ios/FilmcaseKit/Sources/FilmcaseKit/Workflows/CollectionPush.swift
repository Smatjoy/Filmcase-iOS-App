// Push a whole collection: one recipe per custom slot, in slot order, each through
// SlotBackupWorkflow (so every slot is backed up first). The person drags recipes into slots,
// which arrives here as [SlotIndex: RecipeID]. A connection loss stops the run and the
// report says which slots are done, so it can resume with only the rest; a slot that
// partially failed is reported and the run carries on.

import Foundation

public typealias SlotIndex = Int
public typealias RecipeID = Int

/// An assignment or a run that cannot go ahead. For the validation cases nothing was written.
public enum CollectionPushError: Error, Equatable, Sendable {
    case emptyAssignment
    /// A slot outside 1...slotCount (the camera model's custom slots).
    case slotOutOfRange(slot: SlotIndex, slotCount: Int)
    /// The same slot assigned twice (only detectable in a list of pairs).
    case duplicateSlot(SlotIndex)
    /// A slot assigned a recipe that was not supplied.
    case unknownRecipe(RecipeID)
    /// A recipe the camera cannot take; checked for every slot before the first write.
    case invalidRecipe(slot: SlotIndex, message: String)
    /// No camera is connected.
    case notConnected
    /// A slot's push threw (for instance its backup could not be stored). The slot was not
    /// written; `report` says what was done before it.
    case stopped(report: CollectionPushReport, message: String)
}

/// One step of a run: a slot starting, or finishing with a result.
public struct CollectionPushProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case started
        case finished(SlotPushResult)
    }

    public let slot: SlotIndex
    public let recipeID: RecipeID
    public let phase: Phase
    /// Slots finished so far in this run, this one included once finished.
    public let completed: Int
    public let total: Int
}

/// Where a run got to. `done` slots were attempted and the camera answered (verified or
/// partially failed); `remaining` were not pushed, including the slot the connection was
/// lost on.
public struct CollectionPushReport: Equatable, Sendable {
    public let assignment: [SlotIndex: RecipeID]
    public let results: [SlotIndex: SlotPushResult]
    public let done: [SlotIndex]
    public let remaining: [SlotIndex]

    public var isComplete: Bool { remaining.isEmpty }
    public var failedSlots: [SlotIndex] {
        done.filter { if case .partiallyFailed = results[$0] { return true } else { return false } }
    }
}

/// A running push: its progress, and its final report.
public struct CollectionPushRun: Sendable {
    public let progress: AsyncStream<CollectionPushProgress>
    let task: Task<CollectionPushReport, any Error>

    /// The report, when the run ends. Throws what `CollectionPushError.stopped` carries.
    public var report: CollectionPushReport {
        get async throws { try await task.value }
    }

    public func cancel() { task.cancel() }
}

public struct CollectionPush: Sendable {
    let workflow: SlotBackupWorkflow
    let clock: any FilmcaseClock

    public init(workflow: SlotBackupWorkflow, clock: any FilmcaseClock = SystemClock()) {
        self.workflow = workflow
        self.clock = clock
    }

    /// Turn the order the person arranged into an assignment, rejecting a slot used twice.
    public static func assignment(
        from pairs: [(slot: SlotIndex, recipe: RecipeID)]
    ) throws -> [SlotIndex: RecipeID] {
        var assignment: [SlotIndex: RecipeID] = [:]
        for (slot, recipe) in pairs {
            if assignment[slot] != nil { throw CollectionPushError.duplicateSlot(slot) }
            assignment[slot] = recipe
        }
        return assignment
    }

    /// Check an assignment against the camera's slot count and the recipes supplied.
    public static func validate(
        assignment: [SlotIndex: RecipeID], recipes: [RecipeID: Recipe], slotCount: Int
    ) throws {
        guard !assignment.isEmpty else { throw CollectionPushError.emptyAssignment }
        for slot in assignment.keys.sorted() {
            guard slotCount > 0, (1...slotCount).contains(slot) else {
                throw CollectionPushError.slotOutOfRange(slot: slot, slotCount: slotCount)
            }
            if let id = assignment[slot], recipes[id] == nil {
                throw CollectionPushError.unknownRecipe(id)
            }
        }
    }

    /// Push *assignment*, slot by slot in ascending order.
    ///
    /// Validated up front, before any write: the assignment, and every recipe against the
    /// camera. Between slots it waits `CAMERA_INTER_SLOT_DELAY_S`.
    /// - Throws: `CollectionPushError` (validation cases are thrown here; `.stopped` from `run.report`).
    public func start(
        recipes: [RecipeID: Recipe], assignment: [SlotIndex: RecipeID]
    ) async throws -> CollectionPushRun {
        guard let cameraName = await workflow.runner.cameraName else { throw CollectionPushError.notConnected }
        let encodings = workflow.runtime.config.encodings
        try Self.validate(
            assignment: assignment, recipes: recipes,
            slotCount: customSlotCount(cameraName: cameraName, encodings: encodings))
        let strategy = getStrategy(cameraName: cameraName)
        for slot in assignment.keys.sorted() {
            guard let id = assignment[slot], let recipe = recipes[id] else { continue }
            do {
                try strategy.validateRecipe(recipe, encodings: encodings)
            } catch {
                throw CollectionPushError.invalidRecipe(slot: slot, message: String(describing: error))
            }
        }
        return launch(recipes: recipes, assignment: assignment, slots: assignment.keys.sorted(), earlier: [:])
    }

    /// Push only what *report* says remains, with the same assignment.
    public func resume(
        from report: CollectionPushReport, recipes: [RecipeID: Recipe]
    ) async throws -> CollectionPushRun {
        guard await workflow.runner.cameraName != nil else { throw CollectionPushError.notConnected }
        for slot in report.remaining {
            if let id = report.assignment[slot], recipes[id] == nil {
                throw CollectionPushError.unknownRecipe(id)
            }
        }
        var earlier = report.results
        for slot in report.remaining { earlier[slot] = nil }
        return launch(
            recipes: recipes, assignment: report.assignment, slots: report.remaining, earlier: earlier)
    }

    private func launch(
        recipes: [RecipeID: Recipe], assignment: [SlotIndex: RecipeID],
        slots: [SlotIndex], earlier: [SlotIndex: SlotPushResult]
    ) -> CollectionPushRun {
        let (stream, continuation) = AsyncStream.makeStream(of: CollectionPushProgress.self)
        let workflow = self.workflow
        let clock = self.clock
        let delay = workflow.runtime.config.settings.cameraInterSlotDelayS
        let task = Task<CollectionPushReport, any Error> {
            defer { continuation.finish() }
            var results = earlier
            var finished = 0

            func report() -> CollectionPushReport {
                let done = assignment.keys.sorted().filter {
                    if let result = results[$0], result != .connectionLost { return true } else { return false }
                }
                let remaining = assignment.keys.sorted().filter { !done.contains($0) }
                return CollectionPushReport(
                    assignment: assignment, results: results, done: done, remaining: remaining)
            }

            for (position, slot) in slots.enumerated() {
                try Task.checkCancellation()
                guard let id = assignment[slot], let recipe = recipes[id] else { continue }
                if position > 0, delay > 0 { try await clock.sleep(for: .seconds(delay)) }

                continuation.yield(CollectionPushProgress(
                    slot: slot, recipeID: id, phase: .started, completed: finished, total: slots.count))
                let result: SlotPushResult
                do {
                    result = try await workflow.push(recipe, to: slot)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CollectionPushError.stopped(report: report(), message: String(describing: error))
                }
                results[slot] = result
                finished += 1
                continuation.yield(CollectionPushProgress(
                    slot: slot, recipeID: id, phase: .finished(result), completed: finished, total: slots.count))
                if result == .connectionLost { break }
            }
            return report()
        }
        return CollectionPushRun(progress: stream, task: task)
    }
}
