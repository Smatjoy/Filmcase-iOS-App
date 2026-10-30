import Foundation

/// What a screen that loads remote content should show.
public enum ContentState: Equatable, Sendable {
    case loading
    case loaded
    case empty
    /// A failure the person can read; the server or the request is at fault.
    case error(String)
    /// No server could be reached.
    case offline

    /// The state a failed load leaves a screen in.
    static func failure(_ error: any Error) -> ContentState {
        switch error as? FilmcaseClientError {
        case .transport, .noReachableServer: .offline
        default: .error(UserMessages.text(for: error))
        }
    }
}
