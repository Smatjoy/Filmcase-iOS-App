// What the Lock Screen / Dynamic Island shows while slots are being written. Plain data,
// no ActivityKit: the app's adapter uses it as the `ActivityAttributes.ContentState` (it is
// Codable). ActivityKit limits the encoded state to about 4 KB, so everything here is small
// and free text is capped; a test pins the encoding of a 7-slot collection push under 4096
// bytes.

import Foundation

public struct PushActivityContent: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// Reserved for a workflow that reports its sub-steps; the models do not emit it today.
        case backingUp
        /// A slot is being backed up and written (the models report this for the whole step).
        case writing
        /// Reserved, like `backingUp`.
        case verifying
        /// Everything was written and read back.
        case done
        /// The camera answered but something did not take, or the run stopped early.
        case partial
        /// The connection was lost.
        case lost
        /// Nothing was written (refused before the write, or cancelled).
        case failed

        public var isFinal: Bool {
            switch self {
            case .done, .partial, .lost, .failed: true
            case .backingUp, .writing, .verifying: false
            }
        }
    }

    /// One slot's mark in the compact strip.
    public struct SlotMark: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Hashable, Sendable {
            case waiting, active, verified, partial, lost
        }

        public let slot: Int
        public let status: Status

        public init(slot: Int, status: Status) {
            self.slot = slot
            self.status = status
        }
    }

    /// The recipe's or collection's name (capped).
    public let title: String
    /// The slot being written, if any.
    public let currentSlot: Int?
    public let completed: Int
    public let total: Int
    public let slots: [SlotMark]
    public let phase: Phase
    /// One short line: "Sending R2 to C2 (1 of 7)".
    public let statusLine: String
    /// The whole state in a sentence for VoiceOver.
    public let accessibilityLabel: String

    public static let maxTitleLength = 40
    public static let maxLineLength = 80
    public static let maxAccessibilityLength = 200

    public init(
        title: String, currentSlot: Int?, completed: Int, total: Int, slots: [SlotMark],
        phase: Phase, statusLine: String, accessibilityLabel: String
    ) {
        self.title = Self.capped(title, Self.maxTitleLength)
        self.currentSlot = currentSlot
        self.completed = completed
        self.total = total
        self.slots = slots
        self.phase = phase
        self.statusLine = Self.capped(statusLine, Self.maxLineLength)
        self.accessibilityLabel = Self.capped(accessibilityLabel, Self.maxAccessibilityLength)
    }

    /// Progress from 0 to 1 for a gauge.
    public var fractionCompleted: Double {
        total > 0 ? min(1, Double(completed) / Double(total)) : 0
    }

    static func capped(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "\u{2026}"
    }
}

/// How the activity should leave the screen.
public enum PushActivityDismissal: Equatable, Hashable, Sendable {
    /// Remove it now.
    case immediate
    /// Let the system keep it for its default period, so a problem can be read.
    case `default`
    /// Remove it after this many seconds.
    case after(seconds: Double)
}

/// Where activity content goes. The app's ActivityKit adapter implements it; models take it
/// as an optional dependency. A run is `start`, any number of `update`s, then `end`.
public protocol PushActivityReporter: Sendable {
    func start(content: PushActivityContent) async
    func update(_ content: PushActivityContent) async
    func end(_ content: PushActivityContent, dismissal: PushActivityDismissal) async
}

/// Remembers every call, for tests.
public actor RecordingPushActivityReporter: PushActivityReporter {
    public enum Event: Equatable, Sendable {
        case start(PushActivityContent)
        case update(PushActivityContent)
        case end(PushActivityContent, PushActivityDismissal)

        public var content: PushActivityContent {
            switch self {
            case .start(let content), .update(let content), .end(let content, _): content
            }
        }
    }

    public private(set) var events: [Event] = []

    public init() {}

    public func start(content: PushActivityContent) { events.append(.start(content)) }
    public func update(_ content: PushActivityContent) { events.append(.update(content)) }
    public func end(_ content: PushActivityContent, dismissal: PushActivityDismissal) {
        events.append(.end(content, dismissal))
    }
}
