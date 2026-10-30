// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.

import FilmcaseKit
import Foundation
import Network
import Synchronization

/// `NWPathMonitor` as `NetworkPathEvents`. Drops a callback only when its status
/// equals the previous one; every other change is forwarded.
struct PathMonitorEvents: NetworkPathEvents {
    func pathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor() // API: NWPathMonitor.init()
            let last = Mutex<NWPath.Status?>(nil)
            // API: NWPathMonitor.pathUpdateHandler: (@Sendable (NWPath) -> Void)?
            monitor.pathUpdateHandler = { path in
                let status = path.status // API: NWPath.status (NWPath.Status, Equatable)
                let isRepeat = last.withLock { previous in
                    defer { previous = status }
                    return previous == status
                }
                if !isRepeat { continuation.yield() }
            }
            continuation.onTermination = { _ in
                monitor.cancel() // API: NWPathMonitor.cancel()
            }
            // API: NWPathMonitor.start(queue: DispatchQueue)
            monitor.start(queue: DispatchQueue(label: "dev.filmcase.path-monitor"))
        }
    }
}
