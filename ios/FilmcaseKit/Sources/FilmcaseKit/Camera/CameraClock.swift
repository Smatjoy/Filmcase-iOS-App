// Mirrors: the `sleep` half of the JS `runtime` ({config, sleep}) passed to every
// operation in src/interfaces/static/js/camera/domain/*.js (the Python uses time.sleep).
// Injected everywhere a delay is needed so tests and the demo build record instead of wait.
// Strategies sleep in seconds (the served settings are `*_S` doubles); `ClockSleeper` adapts
// the module-wide `FilmcaseClock` to that, so there is one time source.

import Foundation

/// Something that can wait. Production waits for real; tests record the request.
public protocol CameraSleeper: Sendable {
    func sleep(seconds: Double) async throws
}

/// Adapts a `FilmcaseClock` to the seconds-based `CameraSleeper` the strategies use.
/// Non-positive durations return immediately, without asking the clock.
public struct ClockSleeper<C: FilmcaseClock>: CameraSleeper {
    public let clock: C

    public init(clock: C) {
        self.clock = clock
    }

    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await clock.sleep(for: .seconds(seconds))
    }
}

/// Waits for real, through `SystemClock`.
public struct SystemCameraSleeper: CameraSleeper {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await ClockSleeper(clock: SystemClock()).sleep(seconds: seconds)
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

    /// A runtime whose delays go through *clock*.
    public init(config: ClientConfig, clock: some FilmcaseClock) {
        self.init(config: config, sleeper: ClockSleeper(clock: clock))
    }

    func sleep(_ seconds: Double) async throws {
        try await sleeper.sleep(seconds: seconds)
    }
}
