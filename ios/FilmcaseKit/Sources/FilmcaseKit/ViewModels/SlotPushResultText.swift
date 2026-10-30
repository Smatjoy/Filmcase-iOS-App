// Display words and a mark for one slot's push result, so views show them without deciding.

import Foundation

extension SlotPushResult {
    /// "Verified", "2 settings not applied", "Not pushed \u{2014} connection lost".
    public var displayText: String { UserMessages.text(for: self) }

    /// For VoiceOver; names what did not take.
    public var accessibilityText: String { UserMessages.accessibilityText(for: self) }

    public var indicator: CollectionPushModel.StatusIndicator {
        switch self {
        case .verified: .success
        case .partiallyFailed: .warning
        case .connectionLost: .failure
        }
    }
}
