// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
// Adapter only: FilmcaseKit decides what the content says and when to start, update and end.

import ActivityKit  // API: Activity, ActivityContent, ActivityAuthorizationInfo, ActivityUIDismissalPolicy
import FilmcaseKit
import Foundation

actor ActivityKitPushReporter: PushActivityReporter {
    /// If no update arrives within this time the system marks the content stale.
    static let staleAfter: TimeInterval = 300

    /// The live activity's id, not the `Activity` itself: `Activity` is not Sendable and its
    /// update/end are `@concurrent`, so an actor-held instance cannot be sent to them under
    /// Swift 6. A fresh lookup by id is a disconnected value that can.
    private var currentID: String?

    init() {}

    func start(content: PushActivityContent) async {
        // API: ActivityAuthorizationInfo().areActivitiesEnabled
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        await endCurrent()
        do {
            // API: Activity.request(attributes:content:pushType:); pushType nil = local updates only
            currentID = try Activity.request(
                attributes: PushActivityAttributes(kind: "push"),
                content: Self.activityContent(content),
                pushType: nil
            ).id
        } catch {
            // A Live Activity is a nicety: a refusal (too many, disabled) must not affect the push.
            currentID = nil
        }
    }

    func update(_ content: PushActivityContent) async {
        guard let currentID else { return }
        await Self.update(id: currentID, Self.activityContent(content))
    }

    func end(_ content: PushActivityContent, dismissal: PushActivityDismissal) async {
        guard let id = currentID else { return }
        currentID = nil
        await Self.end(id: id, Self.activityContent(content), policy: Self.policy(for: dismissal))
    }

    /// A still-live activity (a previous run that never ended) goes before a new one starts.
    private func endCurrent() async {
        guard let id = currentID else { return }
        currentID = nil
        await Self.end(id: id, nil, policy: .immediate)
    }

    // API: Activity<Attributes>.activities, Activity.id
    private static func live(_ id: String) -> Activity<PushActivityAttributes>? {
        Activity<PushActivityAttributes>.activities.first { $0.id == id }
    }

    // API: Activity.update(_ content: ActivityContent<ContentState>) async
    private static func update(id: String, _ content: ActivityContent<PushActivityContent>) async {
        guard let activity = live(id) else { return }
        await activity.update(content)
    }

    // API: Activity.end(_:dismissalPolicy:) async
    private static func end(
        id: String, _ content: ActivityContent<PushActivityContent>?, policy: ActivityUIDismissalPolicy
    ) async {
        guard let activity = live(id) else { return }
        await activity.end(content, dismissalPolicy: policy)
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
