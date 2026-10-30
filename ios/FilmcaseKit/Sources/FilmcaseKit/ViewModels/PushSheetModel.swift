// "Send to camera" for one recipe: pick a slot, confirm the overwrite, push (the workflow
// backs the slot up first), then show the result and offer to restore the backup.

import Foundation
import Observation

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
    public private(set) var slots: [SlotItem]
    public private(set) var phase: Phase = .choosingSlot
    /// Count of verified pushes or restores, for `.sensoryFeedback(.success, trigger:)`.
    public private(set) var successCount = 0
    /// Count of partial failures, losses and refusals, for `.sensoryFeedback(.warning, trigger:)`.
    public private(set) var problemCount = 0
    /// The backup taken by the last push, until it has been restored.
    public private(set) var lastBackup: SlotBackup?

    @ObservationIgnored private let workflow: SlotBackupWorkflow

    public init(recipe: Recipe, slots: [SlotItem], workflow: SlotBackupWorkflow) {
        self.recipe = recipe
        self.slots = slots
        self.workflow = workflow
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
        self.slots = slots
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
    }

    // --- internals ---

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
