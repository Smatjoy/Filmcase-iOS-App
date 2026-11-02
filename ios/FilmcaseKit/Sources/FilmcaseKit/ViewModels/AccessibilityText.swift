// Words for VoiceOver that views would otherwise build themselves: labels for list rows,
// announcements for results and finished runs, and a fingerprint read in pairs.

import Foundation

extension UserMessages {
    /// "1 recipe", "3 recipes", "0 recipes".
    public static func recipeCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "recipe" : "recipes")"
    }

    /// Said after a search or filter change: "12 recipes", "1 recipe", "No recipes match".
    public static func resultsAnnouncement(count: Int) -> String {
        count <= 0 ? "No recipes match" : recipeCountText(count)
    }

    /// "1 slot", "7 slots".
    static func slotCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "slot" : "slots")"
    }
}

extension CollectionSummary {
    /// "Name, 3 recipes"; "1 recipe" when there is one; "Untitled collection" for a blank name.
    public var accessibilityLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled collection" : trimmed
        return "\(title), \(UserMessages.recipeCountText(recipeCount))"
    }
}

extension FacetOption {
    /// "Kodak Portra 400, 12 recipes": the label when there is one (the sensor facet), else the value.
    public var accessibilityLabel: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? value : trimmed
        return "\(title), \(UserMessages.recipeCountText(count))"
    }
}

extension SlotPushResult {
    /// "Not applied: Dynamic Range, High Light Tone" for a partial failure; nil otherwise.
    /// Visible text, so the person can see which settings the camera did not take.
    public var detailText: String? {
        guard case .partiallyFailed(let names) = self, !names.isEmpty else { return nil }
        return "Not applied: \(names.map(UserMessages.propertyLabel).joined(separator: ", "))"
    }
}

extension CollectionPushModel.SlotStatus {
    /// The detail line to show under the status; nil unless the slot partially failed.
    public var detailText: String? {
        if case .done(let result) = self { return result.detailText }
        return nil
    }
}

extension PushSheetModel.Outcome {
    /// The same detail line for a single push or restore; nil unless it partially failed.
    public var detailText: String? {
        if case .partiallyFailed(let names) = result { return SlotPushResult.partiallyFailed(names).detailText }
        return nil
    }
}

extension PropertyDiffRow {
    /// "High Light Tone did not take".
    public var accessibilityLabel: String { "\(label) did not take" }
}

extension PushSheetModel.Outcome {
    /// One spoken line per row of `diff`, in the same order.
    public var diffAccessibilityLabels: [String] { diff.map(\.accessibilityLabel) }
}

extension CollectionPushModel {
    /// What to say when the run reaches *phase*; nil for phases with nothing to announce.
    public static func completionAnnouncement(for phase: Phase) -> String? {
        switch phase {
        case .editing, .running:
            return nil
        case .finished(let report):
            let verified = report.done.filter { report.results[$0] == .verified }.count
            let problems = slotProblems(report.done.compactMap { slot in report.results[slot].map { (slot, $0) } })
            if problems.isEmpty { return "Collection pushed: \(verified) verified" }
            return (["\(verified) verified"] + problems).joined(separator: ", ")
        case .interrupted(_, let message):
            return message ?? "The push stopped."
        case .restoring:
            return "Restoring slots"
        case .restored(let results):
            if results.isEmpty { return "Nothing to restore" }
            let restored = results.values.filter { $0 == .verified }.count
            let problems = slotProblems(results.map { ($0.key, $0.value) })
            return (["Restored \(UserMessages.slotCountText(restored))"] + problems).joined(separator: ", ")
        }
    }

    /// The announcement for the current phase.
    public var completionAnnouncement: String? { Self.completionAnnouncement(for: phase) }

    /// "C4: 2 settings not applied" for every slot that did not verify, in slot order.
    private static func slotProblems(_ results: [(SlotIndex, SlotPushResult)]) -> [String] {
        results.sorted { $0.0 < $1.0 }.compactMap { slot, result in
            switch result {
            case .partiallyFailed: "C\(slot): \(UserMessages.text(for: result))"
            case .connectionLost: "C\(slot): not pushed, connection lost"
            case .verified: nil
            }
        }
    }
}

extension OnboardingModel {
    /// The fingerprint for VoiceOver: uppercase pairs with pauses between ("AB, CD, EF").
    public static func spoken(fingerprint: String) -> String {
        formatted(fingerprint: fingerprint).split(separator: ":").joined(separator: ", ")
    }

    /// The fingerprint being asked about, spoken in pairs; nil unless trust is being asked.
    public var accessibilityFingerprint: String? {
        guard case .needsTrust(_, let fingerprint) = state else { return nil }
        return Self.spoken(fingerprint: fingerprint)
    }
}
