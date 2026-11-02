// Turns what the push models know into `PushActivityContent`. Pure functions, so the wording
// and the sizes are tested without a model or a camera.

import Foundation

extension PushActivityContent {
    // --- one recipe to one slot ---

    /// A single push under way. The workflow backs the slot up, then writes.
    public static func singleInProgress(recipeName: String, slot: Int) -> PushActivityContent {
        PushActivityContent(
            title: recipeName, currentSlot: slot, completed: 0, total: 1,
            slots: [SlotMark(slot: slot, status: .active)], phase: .writing,
            statusLine: "Backing up C\(slot), then sending",
            accessibilityLabel: "Sending \(recipeName) to C\(slot). Backing up the slot first.")
    }

    /// A single push that ended with *result*.
    public static func singleFinished(recipeName: String, slot: Int, result: SlotPushResult) -> PushActivityContent {
        let phase: Phase
        let mark: SlotMark.Status
        let line: String
        let spoken: String
        switch result {
        case .verified:
            (phase, mark) = (.done, .verified)
            line = "C\(slot) verified"
            spoken = "\(recipeName) was sent to C\(slot) and verified."
        case .partiallyFailed(let names):
            (phase, mark) = (.partial, .partial)
            line = "C\(slot): \(UserMessages.text(for: result))"
            let failed = names.map(UserMessages.propertyLabel).joined(separator: ", ")
            spoken = "\(recipeName) was sent to C\(slot), but \(failed) did not take."
        case .connectionLost:
            (phase, mark) = (.lost, .lost)
            line = "Camera connection lost"
            spoken = "The camera connection was lost while sending \(recipeName) to C\(slot)."
        }
        return PushActivityContent(
            title: recipeName, currentSlot: nil, completed: phase == .lost ? 0 : 1, total: 1,
            slots: [SlotMark(slot: slot, status: mark)], phase: phase,
            statusLine: line, accessibilityLabel: spoken)
    }

    /// A single push that did not happen: refused before the write, or cancelled.
    public static func singleFailed(recipeName: String, slot: Int, reason: String) -> PushActivityContent {
        PushActivityContent(
            title: recipeName, currentSlot: nil, completed: 0, total: 1,
            slots: [SlotMark(slot: slot, status: .waiting)], phase: .failed,
            statusLine: reason, accessibilityLabel: "\(recipeName) was not sent to C\(slot). \(reason)")
    }

    // --- a collection ---

    /// How a collection run stands.
    public enum CollectionStage: Equatable, Sendable {
        case running
        /// Every slot was attempted: `.done` when all verified, else `.partial`.
        case finished
        /// Stopped early: `connectionLost` picks `.lost`, otherwise `.partial`.
        case stopped(connectionLost: Bool)
        /// Cancelled, or refused before the first write.
        case failed(reason: String)
    }

    /// A collection push. *marks* are the assigned slots in order; *currentName* names the
    /// recipe going into the mark that is `.active`.
    public static func collection(
        title: String, marks: [SlotMark], completed: Int, total: Int, currentName: String?,
        stage: CollectionStage
    ) -> PushActivityContent {
        let current = marks.first { $0.status == .active }?.slot
        let verified = marks.filter { $0.status == .verified }.count
        let partial = marks.filter { $0.status == .partial }.count
        let progress = "\(completed) of \(total)"
        let phase: Phase
        let line: String
        let spoken: String
        switch stage {
        case .running:
            phase = .writing
            if let current, let currentName {
                line = "Sending \(currentName) to C\(current) (\(progress))"
                spoken = "Sending \(currentName) to C\(current) in \(title). \(progress) slots done."
            } else {
                line = "Sending, \(progress) done"
                spoken = "Sending \(title). \(progress) slots done."
            }
        case .finished:
            if partial == 0 {
                phase = .done
                line = "\(verified) of \(total) verified"
                spoken = "\(title) was sent. \(verified) of \(total) slots verified."
            } else {
                phase = .partial
                line = "\(verified) verified, \(partial) need attention"
                spoken = "\(title) was sent. \(verified) slots verified, \(partial) did not fully take."
            }
        case .stopped(let lost):
            phase = lost ? .lost : .partial
            line = lost ? "Connection lost after \(progress)" : "Stopped after \(progress)"
            spoken = (lost ? "The camera connection was lost while sending \(title). " : "Sending \(title) stopped. ")
                + "\(progress) slots done."
        case .failed(let reason):
            phase = .failed
            line = reason
            spoken = "\(title) was not sent. \(reason)"
        }
        return PushActivityContent(
            title: title, currentSlot: phase.isFinal ? nil : current, completed: completed, total: total,
            slots: marks, phase: phase, statusLine: line, accessibilityLabel: spoken)
    }

    /// How the activity should leave the screen once it ended with this content.
    public var suggestedDismissal: PushActivityDismissal {
        switch phase {
        case .done: .after(seconds: 10)
        case .partial, .lost: .default
        case .failed: .immediate
        case .backingUp, .writing, .verifying: .default
        }
    }
}
