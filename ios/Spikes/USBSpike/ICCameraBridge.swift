// Throwaway spike code (S1). NOT compiled on Linux: written for Xcode 26 / iOS 26 SDK, Swift 6.
// Every ImageCaptureCore call carries a `// API:` comment naming the Apple symbol to verify.
//
// Isolation design:
//   - ICCameraBridge is a plain NSObject subclass marked @unchecked Sendable; all its mutable state
//     sits behind one NSLock. It is NOT main-actor isolated.
//   - The delegate witnesses are `nonisolated` and touch only lock-protected state and the
//     AsyncStream continuation (thread-safe), so they are correct whichever queue ImageCaptureCore
//     calls them on.
//   - The methods that call into ImageCaptureCore are @MainActor (ICC is conventionally driven from
//     the main thread).
//   - Every ICC completion handler is built in a `nonisolated static` factory and typed @Sendable.
//     A closure literal written inside a @MainActor method would be inferred main-actor isolated
//     and trap at runtime (dispatch_assert_queue) when ICC calls it from another queue.

@preconcurrency import ImageCaptureCore
import CoreGraphics
import Foundation

// MARK: - Value types crossing isolation boundaries

struct DeviceSnapshot: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let uuid: String
    let transport: String
    let capabilities: [String]
    let canAcceptPTPCommands: Bool
    let hasOpenSession: Bool
}

enum BridgeEvent: Sendable {
    case deviceAdded(DeviceSnapshot)
    case deviceRemoved(id: String)
    case sessionOpened(errorText: String?)
    case sessionClosed(errorText: String?)
    case deviceReady(String)
    case capabilityChanged(DeviceSnapshot)
    case ptpEvent(hex: String)
    case note(String)
}

enum BridgeError: Error, Sendable, CustomStringConvertible {
    case noDevice
    case timeout(String)
    case icc(ErrorInfo)

    var description: String {
        switch self {
        case .noDevice: return "no camera device selected"
        case .timeout(let what): return "timeout waiting for \(what)"
        case .icc(let info): return "\(info.domain) \(info.code): \(info.message)"
        }
    }
}

struct ErrorInfo: Sendable, Equatable {
    let domain: String
    let code: Int
    let message: String

    /// ICReturnPTPNotAuthorizedToSendCommand (value as reported in the field, see docs/ios_app_plan.md).
    static let notAuthorizedCode = -21249

    init(_ error: any Error) {
        let ns = error as NSError
        domain = ns.domain
        code = ns.code
        message = ns.localizedDescription
    }

    var isNotAuthorized: Bool { code == ErrorInfo.notAuthorizedCode }
}

struct RawPTPResult: Sendable {
    let response: [UInt8]
    let inData: [UInt8]
    let error: ErrorInfo?
}

/// Holds a non-Sendable ICCameraDevice inside lock-protected bridge state.
private final class DeviceBox: @unchecked Sendable {
    let device: ICCameraDevice
    init(_ device: ICCameraDevice) { self.device = device }
}

// MARK: - One-shot continuation with timeout

/// Resumes a checked continuation at most once, from whichever of {ICC callback, timeout} comes first.
final class OnceResumer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func arm(timeout: Duration, timeoutError: any Error) {
        let task = Task { [self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self.resume(throwing: timeoutError) }
        }
        let stillPending: Bool = lock.withLock {
            if continuation == nil { return false }
            timer = task
            return true
        }
        if !stillPending { task.cancel() }
    }

    func resume(returning value: T) {
        let (c, t) = takeLocked()
        t?.cancel()
        c?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        let (c, t) = takeLocked()
        t?.cancel()
        c?.resume(throwing: error)
    }

    private func takeLocked() -> (CheckedContinuation<T, any Error>?, Task<Void, Never>?) {
        lock.withLock {
            let c = continuation
            let t = timer
            continuation = nil
            timer = nil
            return (c, t)
        }
    }
}

// MARK: - Bridge

final class ICCameraBridge: NSObject, @unchecked Sendable {
    /// Single-consumer stream of delegate-driven events.
    let events: AsyncStream<BridgeEvent>
    private let eventSink: AsyncStream<BridgeEvent>.Continuation

    private let lock = NSLock()
    private var browser: ICDeviceBrowser?
    private var boxes: [String: DeviceBox] = [:]
    private var selectedID: String?
    private var pendingOpen: OnceResumer<Void>?
    private var pendingClose: OnceResumer<Void>?

    override init() {
        let made = AsyncStream<BridgeEvent>.makeStream()
        events = made.stream
        eventSink = made.continuation
        super.init()
    }

    // MARK: Browser and authorization

    @MainActor
    private func ensureBrowser() -> ICDeviceBrowser {
        if let existing = lock.withLock({ browser }) { return existing }
        // API: ICDeviceBrowser.init()
        let created = ICDeviceBrowser()
        // API: ICDeviceBrowser.delegate (ICDeviceBrowserDelegate?)
        created.delegate = self
        // API: ICDeviceBrowser.browsedDeviceTypeMask (ICDeviceTypeMask); ICDeviceTypeMask.camera;
        //      ICDeviceLocationTypeMask.local. The combined value may or may not be a declared case,
        //      so the optional promotion below compiles whether init(rawValue:) is failable or not.
        let combinedRaw = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        let combined: ICDeviceTypeMask? = ICDeviceTypeMask(rawValue: combinedRaw)
        if let combined {
            created.browsedDeviceTypeMask = combined
        } else {
            created.browsedDeviceTypeMask = .camera
            eventSink.yield(.note("browsedDeviceTypeMask: combined camera|local mask rejected, using .camera only"))
        }
        lock.withLock { browser = created }
        return created
    }

    @MainActor
    func startBrowsing() {
        let b = ensureBrowser()
        // API: ICDeviceBrowser.start()
        b.start()
        eventSink.yield(.note("ICDeviceBrowser.start() called, mask rawValue=\(b.browsedDeviceTypeMask.rawValue)"))
    }

    @MainActor
    func stopBrowsing() {
        // API: ICDeviceBrowser.stop()
        lock.withLock { browser }?.stop()
    }

    @MainActor
    var controlAuthorizationDescription: String {
        // API: ICDeviceBrowser.controlAuthorizationStatus (ICAuthorizationStatus)
        Self.describe(ensureBrowser().controlAuthorizationStatus)
    }

    @MainActor
    var contentsAuthorizationDescription: String {
        // API: ICDeviceBrowser.contentsAuthorizationStatus (ICAuthorizationStatus)
        Self.describe(ensureBrowser().contentsAuthorizationStatus)
    }

    /// Returns the status reported by the completion handler (verbatim description).
    @MainActor
    func requestControlAuthorization() async throws -> String {
        let b = ensureBrowser()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, any Error>) in
            let r = OnceResumer<String>(c)
            r.arm(timeout: .seconds(90), timeoutError: BridgeError.timeout("requestControlAuthorization"))
            // API: ICDeviceBrowser.requestControlAuthorization(completion: @escaping (ICAuthorizationStatus) -> Void)
            b.requestControlAuthorization(completion: Self.authCompletion(r))
        }
    }

    @MainActor
    func requestContentsAuthorization() async throws -> String {
        let b = ensureBrowser()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, any Error>) in
            let r = OnceResumer<String>(c)
            r.arm(timeout: .seconds(90), timeoutError: BridgeError.timeout("requestContentsAuthorization"))
            // API: ICDeviceBrowser.requestContentsAuthorization(completion: @escaping (ICAuthorizationStatus) -> Void)
            b.requestContentsAuthorization(completion: Self.authCompletion(r))
        }
    }

    nonisolated private static func authCompletion(_ r: OnceResumer<String>) -> @Sendable (ICAuthorizationStatus) -> Void {
        { status in r.resume(returning: ICCameraBridge.describe(status)) }
    }

    nonisolated static func describe(_ status: ICAuthorizationStatus) -> String {
        // API: ICAuthorizationStatus is an NS_TYPED_ENUM over NSString (.notDetermined, .restricted, .denied, .authorized)
        switch status {
        case .notDetermined: return "notDetermined (raw \(status.rawValue))"
        case .restricted: return "restricted (raw \(status.rawValue))"
        case .denied: return "denied (raw \(status.rawValue))"
        case .authorized: return "authorized (raw \(status.rawValue))"
        default: return "unknown (raw \(status.rawValue))"
        }
    }

    // MARK: Device selection and sessions

    func select(id: String) {
        lock.withLock { selectedID = id }
    }

    private func selectedBox() -> DeviceBox? {
        lock.withLock {
            if let id = selectedID, let box = boxes[id] { return box }
            return boxes.values.first
        }
    }

    @MainActor
    func hasOpenSession() -> Bool {
        // API: ICDevice.hasOpenSession (Bool)
        selectedBox()?.device.hasOpenSession ?? false
    }

    @MainActor
    func refreshedSnapshot() -> DeviceSnapshot? {
        selectedBox().map { Self.snapshot(of: $0.device) }
    }

    /// Opens the ImageCaptureCore session. Never sends a PTP OpenSession.
    @MainActor
    func openSession() async throws {
        guard let device = selectedBox()?.device else { throw BridgeError.noDevice }
        // API: ICDevice.hasOpenSession
        if device.hasOpenSession { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let r = OnceResumer<Void>(c)
            r.arm(timeout: .seconds(30), timeoutError: BridgeError.timeout("didOpenSession"))
            lock.withLock { pendingOpen = r }
            // API: ICDevice.requestOpenSession() ; result arrives via
            //      ICDeviceDelegate.device(_:didOpenSessionWithError:)
            device.requestOpenSession()
        }
    }

    /// Closes the ImageCaptureCore session. Never sends a PTP CloseSession.
    @MainActor
    func closeSession() async throws {
        guard let device = selectedBox()?.device else { throw BridgeError.noDevice }
        // API: ICDevice.hasOpenSession
        if !device.hasOpenSession { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let r = OnceResumer<Void>(c)
            r.arm(timeout: .seconds(30), timeoutError: BridgeError.timeout("didCloseSession"))
            lock.withLock { pendingClose = r }
            // API: ICDevice.requestCloseSession() ; result arrives via
            //      ICDeviceDelegate.device(_:didCloseSessionWithError:)
            device.requestCloseSession()
        }
    }

    // MARK: PTP

    /// Sends one PTP command through ImageCaptureCore. ICC errors are returned inside the result
    /// (so the caller can log domain/code); only a timeout or a missing device throws.
    @MainActor
    func sendPTP(command: Data, outData: Data, timeout: Duration = .seconds(10)) async throws -> RawPTPResult {
        guard let device = selectedBox()?.device else { throw BridgeError.noDevice }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<RawPTPResult, any Error>) in
            let r = OnceResumer<RawPTPResult>(c)
            r.arm(timeout: timeout, timeoutError: BridgeError.timeout("requestSendPTPCommand"))
            // API: ICCameraDevice.requestSendPTPCommand(_ command: Data, outData: Data?,
            //      completion: @escaping (Data, Data, Error?) -> Void). The header names the
            //      block arguments (responseData, ptpResponseData, error): the first is the
            //      data-in phase, the second the PTP response container (confirmed on an X-T50).
            device.requestSendPTPCommand(command, outData: outData, completion: Self.ptpCompletion(r))
        }
    }

    nonisolated private static func ptpCompletion(_ r: OnceResumer<RawPTPResult>) -> @Sendable (Data, Data, (any Error)?) -> Void {
        { inData, responseContainer, error in
            var info: ErrorInfo?
            if let error { info = ErrorInfo(error) }
            r.resume(returning: RawPTPResult(response: [UInt8](responseContainer), inData: [UInt8](inData), error: info))
        }
    }

    // MARK: Snapshot

    nonisolated static func snapshot(of device: ICCameraDevice) -> DeviceSnapshot {
        // API: ICDevice.capabilities ([String]), .name (String?), .uuidString (String?),
        //      .transportType (String?), .hasOpenSession (Bool)
        // The literal equals the value of the NSString constant ICCameraDeviceCanAcceptPTPCommands
        // (API: ICCameraDeviceCanAcceptPTPCommands); the full capability list is logged too.
        let caps: [String] = device.capabilities
        return DeviceSnapshot(
            id: "\(ObjectIdentifier(device).hashValue)",
            name: device.name ?? "(nil name)",
            uuid: device.uuidString ?? "",
            transport: device.transportType ?? "",
            capabilities: caps,
            canAcceptPTPCommands: caps.contains("ICCameraDeviceCanAcceptPTPCommands"),
            hasOpenSession: device.hasOpenSession
        )
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ICCameraBridge: ICDeviceBrowserDelegate {
    // API: ICDeviceBrowserDelegate.deviceBrowser(_:didAdd:moreComing:) (required)
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else {
            eventSink.yield(.note("non-camera device ignored: \(device.name ?? "?")"))
            return
        }
        // API: ICDevice.delegate (ICDeviceDelegate?)
        camera.delegate = self
        let snap = ICCameraBridge.snapshot(of: camera)
        lock.withLock {
            boxes[snap.id] = DeviceBox(camera)
            if selectedID == nil { selectedID = snap.id }
        }
        eventSink.yield(.deviceAdded(snap))
    }

    // API: ICDeviceBrowserDelegate.deviceBrowser(_:didRemove:moreGoing:) (required)
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        removeDevice(device)
    }

    nonisolated fileprivate func removeDevice(_ device: ICDevice) {
        let id = "\(ObjectIdentifier(device).hashValue)"
        lock.withLock {
            boxes[id] = nil
            if selectedID == id { selectedID = nil }
        }
        eventSink.yield(.deviceRemoved(id: id))
    }
}

// MARK: - ICCameraDeviceDelegate (and inherited ICDeviceDelegate)

extension ICCameraBridge: ICCameraDeviceDelegate {
    // API: ICDeviceDelegate.didRemove(_:) (required)
    nonisolated func didRemove(_ device: ICDevice) {
        removeDevice(device)
    }

    // API: ICDeviceDelegate.device(_:didOpenSessionWithError:) (required)
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let pending: OnceResumer<Void>? = lock.withLock {
            let p = pendingOpen
            pendingOpen = nil
            return p
        }
        if let error {
            let info = ErrorInfo(error)
            pending?.resume(throwing: BridgeError.icc(info))
            eventSink.yield(.sessionOpened(errorText: "\(info.domain) \(info.code): \(info.message)"))
        } else {
            pending?.resume(returning: ())
            eventSink.yield(.sessionOpened(errorText: nil))
        }
    }

    // API: ICDeviceDelegate.device(_:didCloseSessionWithError:) (required)
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        let pending: OnceResumer<Void>? = lock.withLock {
            let p = pendingClose
            pendingClose = nil
            return p
        }
        if let error {
            let info = ErrorInfo(error)
            pending?.resume(throwing: BridgeError.icc(info))
            eventSink.yield(.sessionClosed(errorText: "\(info.domain) \(info.code): \(info.message)"))
        } else {
            pending?.resume(returning: ())
            eventSink.yield(.sessionClosed(errorText: nil))
        }
    }

    // API: ICDeviceDelegate.deviceDidBecomeReady(_:) (optional)
    nonisolated func deviceDidBecomeReady(_ device: ICDevice) {
        eventSink.yield(.deviceReady("deviceDidBecomeReady"))
    }

    // API: ICCameraDeviceDelegate.deviceDidBecomeReady(withCompleteContentCatalog:) (required, takes ICCameraDevice)
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        eventSink.yield(.deviceReady("deviceDidBecomeReady(withCompleteContentCatalog:)"))
    }

    // API: ICDeviceDelegate.device(_:didEncounterError:) (optional)
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        let text = error.map { "\(ErrorInfo($0).domain) \(ErrorInfo($0).code)" } ?? "nil"
        eventSink.yield(.note("device(_:didEncounterError:) \(text)"))
    }

    // API: ICCameraDeviceDelegate.cameraDeviceDidChangeCapability(_:) (required)
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        eventSink.yield(.capabilityChanged(ICCameraBridge.snapshot(of: camera)))
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didAdd:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        eventSink.yield(.note("cameraDevice didAdd \(items.count) items"))
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didRemove:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        eventSink.yield(.note("cameraDevice didRemove \(items.count) items"))
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didRenameItems:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        eventSink.yield(.note("cameraDevice didRenameItems \(items.count)"))
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didReceiveThumbnail:for:error:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {
        // Not used by the spike.
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didReceiveMetadata:for:error:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {
        // Not used by the spike.
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didCompleteDeleteFilesWithError:) (optional)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?) {
        // Not used by the spike.
    }

    // API: ICCameraDeviceDelegate.cameraDevice(_:didReceivePTPEvent:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        eventSink.yield(.ptpEvent(hex: ICCameraBridge.hex([UInt8](eventData))))
    }

    // API: ICCameraDeviceDelegate.cameraDeviceDidRemoveAccessRestriction(_:) (required)
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        eventSink.yield(.note("cameraDeviceDidRemoveAccessRestriction"))
    }

    // API: ICCameraDeviceDelegate.cameraDeviceDidEnableAccessRestriction(_:) (required)
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        eventSink.yield(.note("cameraDeviceDidEnableAccessRestriction"))
    }

    nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
