import Foundation
import Synchronization

/// Where the user's server URLs are remembered (LAN first, Tailscale second). The app's
/// `UserDefaults`-backed `EndpointSettings` conforms.
public protocol EndpointSettingsStore: Sendable {
    func urls() -> [URL]
    func save(_ urls: [URL])
}

public final class InMemoryEndpointSettingsStore: EndpointSettingsStore {
    private let stored: Mutex<[URL]>

    public init(urls: [URL] = []) {
        stored = Mutex(urls)
    }

    public func urls() -> [URL] { stored.withLock { $0 } }
    public func save(_ urls: [URL]) { stored.withLock { $0 = urls } }
}
