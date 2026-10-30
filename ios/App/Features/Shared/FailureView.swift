import FilmcaseKit
import SwiftUI

/// The error and offline states of any `ContentState`. Wording comes from `UserMessages`.
struct FailureView: View {
    let state: ContentState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .offline:
            ContentUnavailableView {
                Label("Offline", systemImage: "wifi.slash")
            } description: {
                Text(UserMessages.text(for: FilmcaseClientError.noReachableServer))
            } actions: {
                Button("Try Again", action: retry)
            }
        case .error(let message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: retry)
            }
        case .loading, .loaded, .empty:
            EmptyView()
        }
    }
}
