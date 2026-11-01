// Apple-only. Not compiled on Linux; targets Xcode 26 / Swift 6 strict concurrency.
//
// The USB camera transport (P5): ImageCaptureCore callbacks in, CameraTransport events and
// PTP bytes out. It carries no decisions: CameraConnection decides when to open, recover and
// retry, and PTPChannelDevice (FilmcaseKit) owns the PTP framing measured in spike S1
// (docs/ios_usb_spike.md). The patterns here (lock-guarded state, nonisolated delegate
// callbacks, one-shot continuations) are the ones the spike ran on an X-T50.

@preconcurrency import ImageCaptureCore
import FilmcaseKit
import Foundation

final class ICCameraTransport: NSObject, CameraTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let browser: ICDeviceBrowser
    private let lock = NSLock()

    // Guarded by `lock`.
    private var camera: ICCameraDevice?
    private var pendingOpen: OneShot<Void>?
    private var pendingClose: OneShot<Void>?
    private var pendingSends: [UUID: OneShot<PTPExchange>] = [:]

    @MainActor
    override init() {
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
        // API: ICDeviceBrowser.init(), .delegate, .browsedDeviceTypeMask, .start()
        browser = ICDeviceBrowser()
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .camera
        browser.start()
    }

    // MARK: CameraTransport

    var authorizationStatus: CameraAuthorizationStatus {
        get async {
            // API: ICDeviceBrowser.controlAuthorizationStatus (ICAuthorizationStatus, iOS 14+)
            await MainActor.run { Self.map(browser.controlAuthorizationStatus) }
        }
    }

    func requestAuthorization() async -> Bool {
        let status: ICAuthorizationStatus = await withCheckedContinuation { c in
            Task { @MainActor in
                // API: ICDeviceBrowser.requestControlAuthorization(completion:) (iOS 14+)
                browser.requestControlAuthorization { c.resume(returning: $0) }
            }
        }
        let granted = Self.map(status) == .authorized
        if granted {
            // A camera attached before access was granted may not have been reported yet.
            await MainActor.run {
                browser.stop()
                browser.start()
            }
        }
        return granted
    }

    func openSession() async throws -> any PTPDevice {
        guard let camera = lock.withLock({ self.camera }) else {
            throw CameraConnectionError("No camera is attached")
        }
        let box = CameraBox(camera)
        // API: ICDevice.hasOpenSession
        if !camera.hasOpenSession {
            try await awaitOneShot(timeout: .seconds(10), what: "open session", store: { self.pendingOpen = $0 }) {
                // API: ICDevice.requestOpenSession(); completes in device(_:didOpenSessionWithError:)
                box.camera.requestOpenSession()
            }
        }
        // API: ICDevice.name (String?)
        return PTPChannelDevice(cameraName: camera.name ?? "Camera", channel: ICCameraChannel(transport: self, camera: box))
    }

    func closeSession() async {
        guard let camera = lock.withLock({ self.camera }), camera.hasOpenSession else { return }
        let box = CameraBox(camera)
        try? await awaitOneShot(timeout: .seconds(5), what: "close session", store: { self.pendingClose = $0 }) {
            // API: ICDevice.requestCloseSession(); completes in device(_:didCloseSessionWithError:)
            box.camera.requestCloseSession()
        }
    }

    // MARK: PTP

    /// One PTP transaction. Cancelling the calling task (CameraConnection's timeout) fails it.
    fileprivate func send(_ command: [UInt8], dataOut: [UInt8]?, on camera: CameraBox) async throws -> PTPExchange {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<PTPExchange, any Error>) in
                let shot = OneShot(c)
                lock.withLock { pendingSends[id] = shot }
                if Task.isCancelled {
                    finishSend(id, throwing: CameraConnectionError("PTP transaction cancelled"))
                    return
                }
                // API: ICCameraDevice.requestSendPTPCommand(_:outData:completion:) (iOS 13+).
                //      The block's arguments are (data-in, PTP response container, error).
                camera.camera.requestSendPTPCommand(Data(command), outData: dataOut.map { Data($0) }) { [weak self] dataIn, response, error in
                    guard let self else { return }
                    if let error {
                        self.finishSend(id, throwing: CameraConnectionError("PTP transaction failed: \(Self.describe(error))"))
                    } else {
                        let exchange = PTPExchange(dataIn: [UInt8](dataIn), response: [UInt8](response))
                        lock.withLock { pendingSends.removeValue(forKey: id) }?.resume(returning: exchange)
                    }
                }
            }
        } onCancel: {
            finishSend(id, throwing: CameraConnectionError("PTP transaction cancelled"))
        }
    }

    private func finishSend(_ id: UUID, throwing error: CameraConnectionError) {
        lock.withLock { pendingSends.removeValue(forKey: id) }?.resume(throwing: error)
    }

    /// Fail everything in flight: the camera or its session is gone.
    private func failPending(_ message: String) {
        let (sends, open, close) = lock.withLock {
            let taken = (pendingSends.values, pendingOpen, pendingClose)
            pendingSends = [:]
            pendingOpen = nil
            pendingClose = nil
            return taken
        }
        let error = CameraConnectionError(message)
        sends.forEach { $0.resume(throwing: error) }
        open?.resume(throwing: error)
        close?.resume(returning: ())
    }

    private func awaitOneShot(
        timeout: Duration,
        what: String,
        store: @escaping (OneShot<Void>) -> Void,
        start: @escaping @Sendable () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            let shot = OneShot(c)
            lock.withLock { store(shot) }
            shot.arm(timeout: timeout, error: CameraConnectionError("Timed out waiting to \(what)"))
            start()
        }
    }

    // MARK: Helpers

    private static func map(_ status: ICAuthorizationStatus) -> CameraAuthorizationStatus {
        // API: ICAuthorizationStatus is an NS_TYPED_ENUM over NSString.
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    fileprivate static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}

// MARK: - ICDeviceBrowserDelegate

extension ICCameraTransport: ICDeviceBrowserDelegate {
    // API: ICDeviceBrowserDelegate.deviceBrowser(_:didAdd:moreComing:) (required)
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        // API: ICDevice.delegate (ICDeviceDelegate?)
        camera.delegate = self
        lock.withLock { self.camera = camera }
        continuation.yield(.deviceAdded(name: camera.name ?? "Camera"))
    }

    // API: ICDeviceBrowserDelegate.deviceBrowser(_:didRemove:moreGoing:) (required)
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        removed(device)
    }

    nonisolated fileprivate func removed(_ device: ICDevice) {
        let wasOurs = lock.withLock {
            guard camera === device else { return false }
            camera = nil
            return true
        }
        guard wasOurs else { return }
        failPending("The camera was disconnected")
        continuation.yield(.deviceRemoved)
    }
}

// MARK: - ICCameraDeviceDelegate (and inherited ICDeviceDelegate)

extension ICCameraTransport: ICCameraDeviceDelegate {
    // API: ICDeviceDelegate.didRemove(_:) (required)
    nonisolated func didRemove(_ device: ICDevice) {
        removed(device)
    }

    // API: ICDeviceDelegate.device(_:didOpenSessionWithError:) (required)
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let pending = lock.withLock { () -> OneShot<Void>? in
            defer { pendingOpen = nil }
            return pendingOpen
        }
        if let error {
            pending?.resume(throwing: CameraConnectionError("Could not open the camera session: \(Self.describe(error))"))
        } else {
            pending?.resume(returning: ())
        }
    }

    // API: ICDeviceDelegate.device(_:didCloseSessionWithError:) (required). Also sent when
    //      the system ends the session; only that case is reported as an event.
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        let requested = lock.withLock { () -> OneShot<Void>? in
            defer { pendingClose = nil }
            return pendingClose
        }
        if let requested {
            requested.resume(returning: ())
            return
        }
        failPending("The camera session closed")
        continuation.yield(.sessionClosed)
    }

    // API: ICDeviceDelegate.device(_:didEncounterError:) (optional)
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        continuation.yield(.error(error.map(Self.describe) ?? "Camera error"))
    }

    // The rest are required by the protocol and unused: the app never browses camera files.

    // API: ICCameraDeviceDelegate.deviceDidBecomeReady(withCompleteContentCatalog:) (required)
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    // API: ICCameraDeviceDelegate.cameraDeviceDidChangeCapability(_:) (required)
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    // API: ICCameraDeviceDelegate.cameraDevice(_:didAdd:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    // API: ICCameraDeviceDelegate.cameraDevice(_:didRemove:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    // API: ICCameraDeviceDelegate.cameraDevice(_:didRenameItems:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    // API: ICCameraDeviceDelegate.cameraDevice(_:didReceiveThumbnail:for:error:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    // API: ICCameraDeviceDelegate.cameraDevice(_:didReceiveMetadata:for:error:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    // API: ICCameraDeviceDelegate.cameraDevice(_:didReceivePTPEvent:) (required)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    // API: ICCameraDeviceDelegate.cameraDeviceDidRemoveAccessRestriction(_:) (required)
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    // API: ICCameraDeviceDelegate.cameraDeviceDidEnableAccessRestriction(_:) (required)
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

// MARK: - Plumbing

/// The PTP channel for one open session.
private struct ICCameraChannel: PTPCommandChannel {
    let transport: ICCameraTransport
    let camera: CameraBox

    func send(command: [UInt8], dataOut: [UInt8]?) async throws -> PTPExchange {
        try await transport.send(command, dataOut: dataOut, on: camera)
    }
}

/// ICCameraDevice is not Sendable; ImageCaptureCore serialises calls on it internally.
private final class CameraBox: @unchecked Sendable {
    let camera: ICCameraDevice
    init(_ camera: ICCameraDevice) { self.camera = camera }
}

/// A continuation resumed at most once, from a callback, a timeout or a failure sweep.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func arm(timeout: Duration, error: any Error) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.resume(throwing: error) }
        }
        let pending = lock.withLock {
            if continuation != nil { timer = task }
            return continuation != nil
        }
        if !pending { task.cancel() }
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.withLock {
            let c = continuation
            continuation = nil
            timer?.cancel()
            timer = nil
            return c
        }
    }
}
