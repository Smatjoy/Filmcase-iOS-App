// Mirrors: the `sleep` half of the JS `runtime` ({config, sleep}) passed to every
// operation in src/interfaces/static/js/camera/domain/*.js (the Python uses time.sleep).
// Injected everywhere a delay is needed so tests and the demo build record instead of wait.
// The lead reconciles this with the Clock/ abstraction.

import Foundation

/// Something that can wait. Production waits for real; tests record the request.
public protocol CameraSleeper: Sendable {
    func sleep(seconds: Double) async throws
}

/// Waits for real, using `Task.sleep`.
public struct SystemCameraSleeper: CameraSleeper {
    public init() {}

    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The JS `runtime` object: the served config plus the sleeper. Settings (delays, retry
/// counts) and encodings are read from the config, never hard-coded.
public struct CameraRuntime: Sendable {
    public var config: ClientConfig
    public var sleeper: any CameraSleeper

    public init(config: ClientConfig, sleeper: any CameraSleeper) {
        self.config = config
        self.sleeper = sleeper
    }

    func sleep(_ seconds: Double) async throws {
        try await sleeper.sleep(seconds: seconds)
    }
}
