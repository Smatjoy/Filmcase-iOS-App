// Compiled into BOTH the app and the widget extension (see project.yml), so the activity the app
// starts and the view the extension draws agree on one type.

import ActivityKit  // API: ActivityAttributes
import FilmcaseKit

/// The Live Activity for a push to the camera. All the dynamic data is `PushActivityContent`
/// from FilmcaseKit; the adapter makes no decisions about it.
struct PushActivityAttributes: ActivityAttributes {
    // API: ActivityAttributes.ContentState must be Codable & Hashable; PushActivityContent is both.
    typealias ContentState = PushActivityContent

    /// Fixed for the life of the activity.
    let kind: String
}
