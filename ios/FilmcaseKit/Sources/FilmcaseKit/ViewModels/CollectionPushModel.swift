// Pushing a whole collection: arrange recipes into slots, validate, run with per-slot
// progress, resume after the connection is lost, and restore everything the run replaced.

import Foundation
import Observation

@MainActor
@Observable
public final class CollectionPushModel {
    public struct Item: Equatable, Identifiable, Sendable {
        public let id: RecipeID
        public let name: String

        public init(id: RecipeID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One row of the slot list.
    public struct SlotRow: Equatable, Identifiable, Sendable {
        public let slot: SlotIndex
        public let item: Item?
        public var id: Int { slot }
        public var title: String { "C\(slot)" }
        /// The recipe's name, or "Empty".
        public var displayName: String { item?.name ?? "Empty" }
    }

    /// Which mark a status gets in a row.
    public enum StatusIndicator: Equatable, Sendable {
        case none
        case progress
        case success
        case warning
        case failure
    }

    public enum SlotStatus: Equatable, Sendable {
        /// Not part of the run yet, or not reached.
        case waiting
        case pushing
        case done(SlotPushResult)

        /// Short words for the row, or nil when there is nothing to say yet.
        public var displayText: String? {
            switch self {
            case .waiting: nil
            case .pushing: "Pushing"
            case .done(let result): UserMessages.text(for: result)
            }
        }

        /// The words for VoiceOver.
        public var accessibilityText: String? {
            switch self {
            case .waiting: nil
            case .pushing: "Pushing"
            case .done(let result): UserMessages.accessibilityText(for: result)
            }
        }

        public var indicator: StatusIndicator {
            switch self {
            case .waiting: .none
            case .pushing: .progress
            case .done(let result): result.indicator
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        case editing
        case running
        /// Every assigned slot was pushed.
        case finished(CollectionPushReport)
        /// The run stopped early (connection lost, or a backup could not be stored).
        case interrupted(CollectionPushReport, message: String?)
        case restoring
        case restored([SlotIndex: SlotPushResult])
    }

    public let items: [Item]
    public private(set) var slotCount: Int
    public private(set) var assignment: [SlotIndex: RecipeID] = [:]
    public private(set) var phase: Phase = .editing
    public private(set) var statuses: [SlotIndex: SlotStatus] = [:]
    /// Slots finished so far and slots in the run, for a progress bar.
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var errorMessage: String?
    /// The confirmation to show before `restoreOriginals()`; nil when none is pending.
    public private(set) var restoreOriginalsPrompt: String?

    @ObservationIgnored private let recipes: [RecipeID: Recipe]
    @ObservationIgnored private let workflow: SlotBackupWorkflow
    @ObservationIgnored private let push: CollectionPush
    /// Backups that existed before the run, so a restore only takes what the run stored.
    @ObservationIgnored private var baselineBackups: Set<SlotBackup.ID>?
    @ObservationIgnored private var lastReport: CollectionPushReport?
    /// Slots finished by earlier runs of the same push (a resume continues the count).
    @ObservationIgnored private var completedBeforeRun = 0
    @ObservationIgnored private let activity: (any PushActivityReporter)?
    @ObservationIgnored private let activityTitle: String

    /// - Parameters:
    ///   - activity: Told about each run (start, a step per slot, end) for a Live Activity.
    ///   - activityTitle: The collection's name, shown as the activity's title.
    public init(
        items: [Item], recipes: [RecipeID: Recipe], slotCount: Int,
        workflow: SlotBackupWorkflow, clock: any FilmcaseClock = SystemClock(),
        activity: (any PushActivityReporter)? = nil, activityTitle: String = "Collection"
    ) {
        self.activity = activity
        self.activityTitle = activityTitle
        self.items = items
        self.recipes = recipes
        self.slotCount = slotCount
        self.workflow = workflow
        self.push = CollectionPush(workflow: workflow, clock: clock)
        autoFill()
    }

    /// Load the camera payload of every recipe in *collection* and build the model.
    public static func load(
        collection: CollectionDetail, client: FilmcaseClient, workflow: SlotBackupWorkflow,
        clock: any FilmcaseClock = SystemClock(), activity: (any PushActivityReporter)? = nil
    ) async throws -> CollectionPushModel {
        let members = CollectionsModel.ordered(collection)
        var recipes: [RecipeID: Recipe] = [:]
        for member in members {
            let data = try await client.cameraPayload(recipeId: member.id)
            do {
                recipes[member.id] = try JSONDecoder().decode(Recipe.self, from: data)
            } catch let error as DecodingError {
                throw FilmcaseClientError.decoding(String(describing: error))
            }
        }
        var slotCount = 7
        if let name = await workflow.runner.cameraName {
            slotCount = customSlotCount(cameraName: name, encodings: workflow.runtime.config.encodings)
        }
        return CollectionPushModel(
            items: members.map { Item(id: $0.id, name: $0.name) }, recipes: recipes,
            slotCount: slotCount, workflow: workflow, clock: clock,
            activity: activity, activityTitle: collection.name)
    }

    // --- derived ---

    public var rows: [SlotRow] {
        guard slotCount > 0 else { return [] }
        return (1...slotCount).map { slot in
            SlotRow(slot: slot, item: assignment[slot].flatMap { id in items.first { $0.id == id } })
        }
    }

    public var unassignedItems: [Item] {
        let assigned = Set(assignment.values)
        return items.filter { !assigned.contains($0.id) }
    }

    /// Why the run cannot start, in the order to show them. Empty means it can.
    public var validationMessages: [String] {
        var messages: [String] = []
        if slotCount == 0 {
            messages.append("The camera has no custom slots.")
        } else if assignment.isEmpty {
            messages.append(UserMessages.text(for: CollectionPushError.emptyAssignment))
        }
        let encodings = workflow.runtime.config.encodings
        for slot in assignment.keys.sorted() {
            guard let id = assignment[slot], let recipe = recipes[id] else {
                messages.append(UserMessages.text(for: CollectionPushError.unknownRecipe(assignment[slot] ?? 0)))
                continue
            }
            do {
                try validateRecipeForCamera(recipe, encodings: encodings)
            } catch {
                messages.append("C\(slot), \(recipe.name): \(UserMessages.text(for: error))")
            }
        }
        return messages
    }

    public var canStart: Bool {
        phase == .editing && validationMessages.isEmpty
    }

    public var canResume: Bool {
        if case .interrupted = phase { return true }
        return false
    }

    public var canRestoreAll: Bool {
        switch phase {
        case .finished, .interrupted: baselineBackups != nil
        default: false
        }
    }

    /// Whether the oldest backup of each slot can be put back: after any run that ended.
    public var canRestoreOriginals: Bool {
        switch phase {
        case .finished, .interrupted, .restored: true
        default: false
        }
    }

    /// Label for `restoreAll()`, which puts back only what this run replaced.
    public var undoPushLabel: String { UserMessages.undoPushLabel }
    public var restoreOriginalsLabel: String { UserMessages.restoreOriginalsLabel }

    // --- editing ---

    /// Recipes in collection order into C1, C2, ...; what does not fit stays unassigned.
    public func autoFill() {
        guard phase == .editing else { return }
        var filled: [SlotIndex: RecipeID] = [:]
        for (offset, item) in items.prefix(max(slotCount, 0)).enumerated() {
            filled[offset + 1] = item.id
        }
        assignment = filled
    }

    /// Put *recipe* in *slot*, taking it out of any other slot. A recipe already in *slot*
    /// takes the other's place, so moving onto an occupied slot swaps.
    public func assign(_ recipe: RecipeID, to slot: SlotIndex) {
        guard phase == .editing, slotCount > 0, (1...slotCount).contains(slot),
              items.contains(where: { $0.id == recipe })
        else { return }
        let previousSlot = assignment.first { $0.value == recipe }?.key
        let displaced = assignment[slot]
        assignment[slot] = recipe
        if let previousSlot, previousSlot != slot {
            assignment[previousSlot] = displaced
        }
    }

    /// Reorder the C1...Cn rows with `List.onMove` semantics: the rows at *source* are taken out
    /// (keeping their order) and put back before the row that was at *destination*; the rows
    /// in between shift, they do not swap. Empty slots are rows too and move with the rest.
    public func moveRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard phase == .editing, slotCount > 0, !source.isEmpty,
              source.allSatisfy({ (0..<slotCount).contains($0) }),
              (0...slotCount).contains(destination)
        else { return }
        var rows: [RecipeID?] = (1...slotCount).map { assignment[$0] }
        let moving = source.sorted().map { rows[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for offset in source.sorted(by: >) { rows.remove(at: offset) }
        rows.insert(contentsOf: moving, at: insertAt)
        var moved: [SlotIndex: RecipeID] = [:]
        for (offset, recipe) in rows.enumerated() {
            if let recipe { moved[offset + 1] = recipe }
        }
        assignment = moved
    }

    public func clear(slot: SlotIndex) {
        guard phase == .editing else { return }
        assignment[slot] = nil
    }

    public func clearAll() {
        guard phase == .editing else { return }
        assignment = [:]
    }

    /// Back to arranging after a finished, stopped or restored run.
    public func editAgain() {
        switch phase {
        case .finished, .interrupted, .restored:
            phase = .editing
            statuses = [:]
            completed = 0
            total = 0
            errorMessage = nil
            lastReport = nil
            baselineBackups = nil
        default:
            break
        }
    }

    // --- running ---

    public func start() async {
        guard canStart else { return }
        errorMessage = nil
        baselineBackups = Set(((try? await workflow.store.all()) ?? []).map(\.id))
        statuses = Dictionary(uniqueKeysWithValues: assignment.keys.map { ($0, SlotStatus.waiting) })
        completed = 0
        completedBeforeRun = 0
        total = assignment.count
        phase = .running
        do {
            let run = try await push.start(recipes: recipes, assignment: assignment)
            await activity?.start(content: activityContent(stage: .running))
            await follow(run)
        } catch {
            phase = .editing
            baselineBackups = nil
            errorMessage = UserMessages.text(for: error)
        }
    }

    /// Push only the slots a stopped run did not reach.
    public func resume() async {
        guard case .interrupted(let report, _) = phase else { return }
        errorMessage = nil
        phase = .running
        total = report.assignment.count
        completed = report.done.count
        completedBeforeRun = report.done.count
        do {
            let run = try await push.resume(from: report, recipes: recipes)
            await activity?.start(content: activityContent(stage: .running))
            await follow(run)
        } catch {
            phase = .interrupted(report, message: UserMessages.text(for: error))
        }
    }

    /// Put every slot this run replaced back as it was.
    public func restoreAll() async {
        guard canRestoreAll, let report = lastReport, let baseline = baselineBackups else { return }
        let previous = phase
        phase = .restoring
        errorMessage = nil
        var results: [SlotIndex: SlotPushResult] = [:]
        do {
            // Newest first, so the last backup seen for a slot is the oldest of this run: the original.
            var originals: [SlotIndex: SlotBackup] = [:]
            for backup in try await workflow.store.all() where !baseline.contains(backup.id) {
                originals[backup.slotIndex] = backup
            }
            let slots = report.results.filter { $0.value != .connectionLost }.keys.sorted()
            for slot in slots {
                guard let backup = originals[slot] else { continue }
                let result = try await workflow.restore(backup)
                results[slot] = result
                if result == .connectionLost { break }
            }
            phase = .restored(results)
        } catch is CancellationError {
            phase = previous
        } catch {
            errorMessage = UserMessages.text(for: error)
            phase = results.isEmpty ? previous : .restored(results)
        }
    }

    /// Work out what restoring the originals would bring back and set
    /// `restoreOriginalsPrompt` for the view to confirm; `errorMessage` says why not otherwise.
    public func requestRestoreOriginals() async {
        guard canRestoreOriginals else { return }
        errorMessage = nil
        restoreOriginalsPrompt = nil
        do {
            guard let originals = try await connectedOriginals() else {
                errorMessage = UserMessages.text(for: CollectionPushError.notConnected)
                return
            }
            if originals.isEmpty {
                errorMessage = UserMessages.noOriginalsText
            } else {
                restoreOriginalsPrompt = UserMessages.restoreOriginalsPrompt(originals: originals)
            }
        } catch {
            errorMessage = UserMessages.text(for: error)
        }
    }

    public func cancelRestoreOriginals() { restoreOriginalsPrompt = nil }

    /// Put the oldest backup of every slot of the connected camera model back, whichever run
    /// stored it. Each slot is backed up first.
    public func restoreOriginals() async {
        guard canRestoreOriginals else { return }
        restoreOriginalsPrompt = nil
        let previous = phase
        phase = .restoring
        errorMessage = nil
        var results: [SlotIndex: SlotPushResult] = [:]
        do {
            guard let originals = try await connectedOriginals() else {
                errorMessage = UserMessages.text(for: CollectionPushError.notConnected)
                phase = previous
                return
            }
            if originals.isEmpty {
                errorMessage = UserMessages.noOriginalsText
                phase = previous
                return
            }
            try await workflow.restoreOriginals(originals, results: &results)
            phase = .restored(results)
        } catch is CancellationError {
            phase = results.isEmpty ? previous : .restored(results)
        } catch {
            errorMessage = UserMessages.text(for: error)
            phase = results.isEmpty ? previous : .restored(results)
        }
    }

    private func connectedOriginals() async throws -> [SlotBackup]? {
        guard let camera = await workflow.connectedCameraName else { return nil }
        return SlotBackupHistory.originals(in: try await workflow.store.all(), camera: camera)
    }

    // --- internals ---

    private func follow(_ run: CollectionPushRun) async {
        await withTaskCancellationHandler {
            for await progress in run.progress {
                apply(progress)
                await activity?.update(activityContent(stage: .running))
            }
            do {
                let report = try await run.report
                conclude(report, message: nil)
            } catch CollectionPushError.stopped(let report, let message) {
                conclude(report, message: UserMessages.text(for: CollectionPushError.stopped(report: report, message: message)))
            } catch {
                phase = .editing
                statuses = [:]
                baselineBackups = nil
                if !(error is CancellationError) { errorMessage = UserMessages.text(for: error) }
            }
        } onCancel: {
            run.cancel()
        }
        await endActivity()
    }

    // --- live activity ---

    private func marks() -> [PushActivityContent.SlotMark] {
        assignment.keys.sorted().map { slot in
            let status: PushActivityContent.SlotMark.Status
            switch statuses[slot] ?? .waiting {
            case .waiting: status = .waiting
            case .pushing: status = .active
            case .done(.verified): status = .verified
            case .done(.partiallyFailed): status = .partial
            case .done(.connectionLost): status = .lost
            }
            return PushActivityContent.SlotMark(slot: slot, status: status)
        }
    }

    private func activityContent(
        stage: PushActivityContent.CollectionStage
    ) -> PushActivityContent {
        let activeSlot = statuses.first { $0.value == .pushing }?.key
        let name = activeSlot.flatMap { assignment[$0] }.flatMap { id in items.first { $0.id == id }?.name }
        return PushActivityContent.collection(
            title: activityTitle, marks: marks(), completed: completed, total: total,
            currentName: name, stage: stage)
    }

    /// Tell the reporter how this run ended, from the phase it left the model in.
    private func endActivity() async {
        guard let activity else { return }
        let stage: PushActivityContent.CollectionStage
        switch phase {
        case .finished:
            stage = .finished
        case .interrupted(let report, _):
            let lost = report.remaining.first.flatMap { report.results[$0] } == .connectionLost
            stage = .stopped(connectionLost: lost)
        default:
            stage = .failed(reason: errorMessage ?? "Cancelled")
        }
        let content = activityContent(stage: stage)
        await activity.end(content, dismissal: content.suggestedDismissal)
    }

    private func apply(_ progress: CollectionPushProgress) {
        completed = completedBeforeRun + progress.completed
        switch progress.phase {
        case .started: statuses[progress.slot] = .pushing
        case .finished(let result): statuses[progress.slot] = .done(result)
        }
    }

    private func conclude(_ report: CollectionPushReport, message: String?) {
        lastReport = report
        for slot in report.assignment.keys {
            if let result = report.results[slot], report.done.contains(slot) {
                statuses[slot] = .done(result)
            } else {
                statuses[slot] = .waiting
            }
        }
        completed = report.done.count
        total = report.assignment.count
        if report.isComplete {
            phase = .finished(report)
        } else {
            let lost = report.remaining.first.flatMap { report.results[$0] } == .connectionLost
            phase = .interrupted(
                report, message: message ?? (lost ? "The camera connection was lost." : nil))
        }
    }
}
