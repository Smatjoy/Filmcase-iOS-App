// A scriptable CameraTransport over FakePTPDevice. Public so the app's demo build flavor
// drives the real CameraConnection and workflows without a camera.
//
// Device calls are numbered across the whole transport (1, 2, 3, ...; reopened sessions keep
// counting) so a script can say "stall the 5th call" or "unplug during the 9th". A stalled
// call is dropped, as the real X-S10 drops a request it never answers: it suspends until its
// task is cancelled and never reaches the underlying FakePTPDevice.

import Foundation

public actor FakeCameraTransport: CameraTransport {
    /// The camera behind the transport; inspect `events` / `writes` on it.
    public nonisolated let device: FakePTPDevice
    public nonisolated let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private var status: CameraAuthorizationStatus
    private let grantsAuthorization: Bool
    private var attached: Bool
    private var stallCalls: Set<Int>
    private var unplugOnCall: Int?
    private let failOpens: Set<Int>

    /// Device calls made so far, across sessions.
    public private(set) var callCount = 0
    public private(set) var openCount = 0
    public private(set) var closeCount = 0

    /// - Parameters:
    ///   - authorizationStatus: Starting status; `.notDetermined` makes the connection ask.
    ///   - grantsAuthorization: Answer to the request: false denies access.
    ///   - attached: Whether a camera is plugged in at the start (reported as `deviceAdded`).
    ///   - stallOnCalls: Device calls (1-based) that never answer.
    ///   - unplugOnCall: The device call during which the camera is removed. It never answers,
    ///     and every later call, and `openSession`, fails with `CameraConnectionError`.
    ///   - failOpens: `openSession` calls (1-based) that fail with `CameraConnectionError`.
    public init(
        device: FakePTPDevice = FakePTPDevice(),
        authorizationStatus: CameraAuthorizationStatus = .notDetermined,
        grantsAuthorization: Bool = true,
        attached: Bool = true,
        stallOnCalls: Set<Int> = [],
        unplugOnCall: Int? = nil,
        failOpens: Set<Int> = []
    ) {
        self.device = device
        self.status = authorizationStatus
        self.grantsAuthorization = grantsAuthorization
        self.attached = attached
        self.stallCalls = stallOnCalls
        self.unplugOnCall = unplugOnCall
        self.failOpens = failOpens
        let (stream, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        self.events = stream
        self.continuation = continuation
        if attached { continuation.yield(.deviceAdded(name: device.cameraName)) }
    }

    // --- CameraTransport ---

    public var authorizationStatus: CameraAuthorizationStatus { status }

    public func requestAuthorization() async -> Bool {
        status = grantsAuthorization ? .authorized : .denied
        return grantsAuthorization
    }

    public func openSession() async throws -> any PTPDevice {
        openCount += 1
        guard attached else { throw CameraConnectionError("No camera attached") }
        if failOpens.contains(openCount) {
            throw CameraConnectionError("Camera refused to open a session")
        }
        return FakeSessionDevice(transport: self, base: device)
    }

    public func closeSession() async {
        closeCount += 1
    }

    // --- scripting ---

    /// Make the *call*-th device call (1-based) never answer.
    public func stall(onCall call: Int) { stallCalls.insert(call) }

    /// Remove the camera during the *call*-th device call.
    public func unplug(onCall call: Int) { unplugOnCall = call }

    /// Plug the camera in (reported as `deviceAdded`).
    public func plugIn() {
        attached = true
        continuation.yield(.deviceAdded(name: device.cameraName))
    }

    /// Remove the camera between calls.
    public func unplug() {
        attached = false
        continuation.yield(.deviceRemoved)
    }

    /// Report that the platform closed the session.
    public func closeSessionFromCamera() { continuation.yield(.sessionClosed) }

    /// Report a platform failure.
    public func reportError(_ message: String) { continuation.yield(.error(message)) }

    // --- used by FakeSessionDevice ---

    fileprivate func gate() async throws {
        callCount += 1
        guard attached else { throw CameraConnectionError("Camera is not attached") }
        if unplugOnCall == callCount {
            attached = false
            continuation.yield(.deviceRemoved)
            try await Task.sleep(for: .seconds(86_400))
        } else if stallCalls.contains(callCount) {
            try await Task.sleep(for: .seconds(86_400))
        }
    }
}

/// The device a fake session hands out: scripted gate first, then the FakePTPDevice.
struct FakeSessionDevice: PTPDevice {
    let transport: FakeCameraTransport
    let base: FakePTPDevice

    var cameraName: String { base.cameraName }

    func getInt(_ code: UInt16) async throws -> Int {
        try await transport.gate()
        return try await base.getInt(code)
    }

    func getString(_ code: UInt16) async throws -> String {
        try await transport.gate()
        return try await base.getString(code)
    }

    func setInt(_ code: UInt16, _ value: Int) async throws -> Int {
        try await transport.gate()
        return try await base.setInt(code, value)
    }

    func setUInt16(_ code: UInt16, _ value: Int) async throws -> Int {
        try await transport.gate()
        return try await base.setUInt16(code, value)
    }

    func setString(_ code: UInt16, _ value: String) async throws -> Int {
        try await transport.gate()
        return try await base.setString(code, value)
    }
}
