// "Send to camera" for one recipe: pick a slot, confirm the overwrite, push (the workflow
// backs the slot up first), then show the result and offer to restore the backup.

import Foundation
import Observation

/// What `PushSheetModel` needs from the camera model. `CameraModel` conforms.
@MainActor
public protocol SlotSource: AnyObject {
    var slots: [SlotItem] { get }
    var slotsState: CameraModel.SlotsState { get }
    var pill: ConnectionPill { get }
    func observe() async
    func connect() async
    func refreshSlots() async
}

extension CameraModel: SlotSource {}

/// A property the camera did not take, named for display.
public struct PropertyDiffRow: Equatable, Identifiable, Sendable {
    /// As the server serves it (`HighLightTone`).
    public let name: String
    /// For display (`High Light Tone`).
    public let label: String
    public var id: String { name }

    init(name: String) {
        self.name = name
        var label = ""
        for character in name {
            if character.isUppercase, !label.isEmpty { label.append(" ") }
            label.append(character)
        }
        self.label = label
    }
}

@MainActor
@Observable
public final class PushSheetModel {
    public struct Outcome: Equatable, Sendable {
        public enum Action: Equatable, Sendable { case push, restore }
        public enum Result: Equatable, Sendable {
            case verified
            /// The camera answered but these properties did not take.
            case partiallyFailed([String])
            case connectionLost
            /// The push could not start, or was refused, with the sentence to show.
            case failed(String)
        }

        public let action: Action
        public let slot: Int
        public let result: Result

        /// The headline for the result: "C3 verified", "C3: 2 settings not applied", ...
        public var message: String {
            switch result {
            case .verified:
                return action == .push ? "C\(slot) verified" : "C\(slot) restored"
            case .partiallyFailed(let names):
                return "C\(slot): \(UserMessages.text(for: SlotPushResult.partiallyFailed(names)))"
            case .connectionLost:
                return "The camera connection was lost"
            case .failed(let text):
                return text
            }
        }

        /// The partially failed properties as a list to render.
        public var diff: [PropertyDiffRow] {
            if case .partiallyFailed(let names) = result { return names.map(PropertyDiffRow.init) }
            return []
        }
    }

    public enum Phase: Equatable, Sendable {
        case choosingSlot
        /// The person tapped a slot; ask before overwriting it.
        case confirming(SlotItem)
        case pushing(slot: Int)
        case restoring(slot: Int)
        case finished(Outcome)
    }

    public let recipe: Recipe
    /// The slots to choose from: the camera model's when the model was made with one (so they
    /// follow it), otherwise the ones given.
    public var slots: [SlotItem] { source?.slots ?? fixedSlots }
    /// Where the slots stand (reading, read, failed). Always `.loaded` without a camera model.
    public var slotsState: CameraModel.SlotsState { source?.slotsState ?? .loaded }
    /// The connection pill to show while there are no slots to choose from; nil without a camera model.
    public var pill: ConnectionPill? { source?.pill }
    public private(set) var phase: Phase = .choosingSlot
    /// Count of verified pushes or restores, for `.sensoryFeedback(.success, trigger:)`.
    public private(set) var successCount = 0
    /// Count of partial failures, losses and refusals, for `.sensoryFeedback(.warning, trigger:)`.
    public private(set) var problemCount = 0
    /// The backup taken by the last push, until it has been restored.
    public private(set) var lastBackup: SlotBackup?

    @ObservationIgnored private let workflow: SlotBackupWorkflow
    @ObservationIgnored private let source: (any SlotSource)?
    private var fixedSlots: [SlotItem]

    /// A model over slots read elsewhere; `updateSlots` replaces them.
    public init(recipe: Recipe, slots: [SlotItem], workflow: SlotBackupWorkflow) {
        self.recipe = recipe
        self.fixedSlots = slots
        self.workflow = workflow
        self.source = nil
    }

    /// A model that owns its slots: it shows the camera model's slots, and reads them again
    /// after every push or restore the camera answered. Run `observe()` from `.task`.
    public init(recipe: Recipe, camera: any SlotSource, workflow: SlotBackupWorkflow) {
        self.recipe = recipe
        self.fixedSlots = []
        self.workflow = workflow
        self.source = camera
    }

    public var canRestore: Bool {
        guard lastBackup != nil, case .finished = phase else { return false }
        return true
    }

    public var isWorking: Bool {
        switch phase {
        case .pushing, .restoring: true
        default: false
        }
    }

    /// The warning shown before the slot is overwritten.
    public var overwriteWarning: String? {
        guard case .confirming(let slot) = phase else { return nil }
        let current = slot.name.isEmpty ? "is empty" : "holds \u{201C}\(slot.name)\u{201D}"
        return "\(slot.title) \(current). It will be backed up, then replaced with \u{201C}\(recipe.name)\u{201D}."
    }

    // --- intents ---

    /// The slots were read again (after a push, say).
    public func updateSlots(_ slots: [SlotItem]) {
        fixedSlots = slots
    }

    /// Follow the camera until the calling task is cancelled (run it from `.task`): connects
    /// when a camera is plugged in and reads the slots. Returns at once without a camera model.
    public func observe() async {
        await source?.observe()
    }

    /// The person asked to connect (no camera found, access denied).
    public func connect() async {
        await source?.connect()
    }

    /// Read the slots again.
    public func refreshSlots() async {
        await source?.refreshSlots()
    }

    public func choose(slot index: Int) {
        guard case .choosingSlot = phase, let slot = slots.first(where: { $0.index == index }) else { return }
        phase = .confirming(slot)
    }

    public func cancelConfirmation() {
        guard case .confirming = phase else { return }
        phase = .choosingSlot
    }

    /// Back to the slot grid after a result.
    public func chooseAnother() {
        guard case .finished = phase else { return }
        phase = .choosingSlot
    }

    /// The person confirmed the overwrite: back up the slot and push.
    public func confirm() async {
        guard case .confirming(let slot) = phase else { return }
        phase = .pushing(slot: slot.index)
        lastBackup = nil
        let camera = await workflow.runner.cameraName
        let before = await latestBackup(slot: slot.index, camera: camera)?.id
        let result: Outcome.Result
        do {
            result = try await Self.map(workflow.push(recipe, to: slot.index))
        } catch is CancellationError {
            phase = .choosingSlot
            return
        } catch {
            result = .failed(UserMessages.text(for: error))
        }
        // Offer a restore only for a backup this push took, never an older one.
        if let backup = await latestBackup(slot: slot.index, camera: camera), backup.id != before {
            lastBackup = backup
        }
        finish(Outcome(action: .push, slot: slot.index, result: result))
        await refreshAfter(result)
    }

    /// Put the slot back as the last push found it.
    public func restore() async {
        guard canRestore, let backup = lastBackup else { return }
        let previous = phase
        phase = .restoring(slot: backup.slotIndex)
        let result: Outcome.Result
        do {
            result = try await Self.map(workflow.restore(backup))
        } catch is CancellationError {
            phase = previous
            return
        } catch {
            result = .failed(UserMessages.text(for: error))
        }
        if result == .verified { lastBackup = nil }
        finish(Outcome(action: .restore, slot: backup.slotIndex, result: result))
        await refreshAfter(result)
    }

    // --- internals ---

    /// The camera answered, so the slot changed (fully or in part): read the slots again.
    private func refreshAfter(_ result: Outcome.Result) async {
        switch result {
        case .verified, .partiallyFailed: await source?.refreshSlots()
        case .connectionLost, .failed: break
        }
    }

    private func finish(_ outcome: Outcome) {
        if outcome.result == .verified { successCount += 1 } else { problemCount += 1 }
        phase = .finished(outcome)
    }

    private func latestBackup(slot: Int, camera: String?) async -> SlotBackup? {
        guard let camera else { return nil }
        return (try? await workflow.store.latest(slot: slot, camera: camera)) ?? nil
    }

    private static func map(_ result: SlotPushResult) -> Outcome.Result {
        switch result {
        case .verified: .verified
        case .partiallyFailed(let names): .partiallyFailed(names)
        case .connectionLost: .connectionLost
        }
    }
}
