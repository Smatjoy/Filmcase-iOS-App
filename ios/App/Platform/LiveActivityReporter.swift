// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
// Adapter only: FilmcaseKit decides what the content says and when to start, update and end.

import ActivityKit  // API: Activity, ActivityContent, ActivityAuthorizationInfo, ActivityUIDismissalPolicy
import FilmcaseKit
import Foundation

actor ActivityKitPushReporter: PushActivityReporter {
    /// If no update arrives within this time the system marks the content stale.
    static let staleAfter: TimeInterval = 300

    private var current: Activity<PushActivityAttributes>?

    init() {}

    func start(content: PushActivityContent) async {
        // API: ActivityAuthorizationInfo().areActivitiesEnabled
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endCurrent()
        do {
            // API: Activity.request(attributes:content:pushType:); pushType nil = local updates only
            current = try Activity.request(
                attributes: PushActivityAttributes(kind: "push"),
                content: Self.activityContent(content),
                pushType: nil)
        } catch {
            // A Live Activity is a nicety: a refusal (too many, disabled) must not affect the push.
            current = nil
        }
    }

    func update(_ content: PushActivityContent) async {
        guard let current else { return }
        // API: Activity.update(_ content: ActivityContent<ContentState>) async
        await current.update(Self.activityContent(content))
    }

    func end(_ content: PushActivityContent, dismissal: PushActivityDismissal) async {
        guard let activity = current else { return }
        current = nil
        // API: Activity.end(_:dismissalPolicy:) async
        await activity.end(Self.activityContent(content), dismissalPolicy: Self.policy(for: dismissal))
    }

    /// A still-live activity (a previous run that never ended) goes before a new one starts.
    private func endCurrent() async {
        guard let activity = current else { return }
        current = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    static func activityContent(_ content: PushActivityContent) -> ActivityContent<PushActivityContent> {
        // API: ActivityContent(state:staleDate:); a finished run does not go stale.
        ActivityContent(
            state: content,
            staleDate: content.phase.isFinal ? nil : Date().addingTimeInterval(staleAfter))
    }

    static func policy(for dismissal: PushActivityDismissal) -> ActivityUIDismissalPolicy {
        switch dismissal {
        case .immediate: .immediate
        case .default: .default
        case .after(let seconds): .after(Date().addingTimeInterval(seconds))
        }
    }
}
