import Foundation
import Synchronization
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

private func body(of config: ClientConfig) -> Data { try! JSONEncoder().encode(config) }

private func serving(_ data: Data) -> @Sendable (URLRequest) -> StubReply {
    { request in isProbe(request) ? .fixture("recipe_list") : .http(status: 200, body: data) }
}

@Suite("CameraRuntimeProvider")
struct CameraRuntimeProviderTests {
    private let bundled = try! TestSupport.makeConfig(["CAMERA_MAX_RETRIES": 1])
    private let served = try! TestSupport.makeConfig(["CAMERA_MAX_RETRIES": 5])

    @Test func startsFromTheBundledSnapshot() async {
        let rig = APIRig(lan: { _ in .transportError() }, tailscale: { _ in .transportError() })
        let provider = CameraRuntimeProvider(
            client: rig.client, cache: InMemoryClientConfigCache(), bundledSnapshot: bundled)
        #expect(await provider.currentRuntime().config == bundled)
        #expect(await provider.source == .bundled)
        #expect(await provider.refresh() == .bundled)
        #expect(await provider.currentRuntime().config == bundled)
    }

    @Test func refreshSwitchesToTheServedConfig() async {
        let rig = APIRig(lan: serving(body(of: served)))
        let provider = CameraRuntimeProvider(
            client: rig.client, cache: InMemoryClientConfigCache(), bundledSnapshot: bundled)
        #expect(await provider.refresh() == .served)
        #expect(await provider.currentRuntime().config == served)
        #expect(await provider.source == .served)
    }

    @Test func aFailedRefreshKeepsWhatIsAlreadyInUse() async {
        let cache = InMemoryClientConfigCache()
        let online = APIRig(lan: serving(body(of: served)))
        let provider = CameraRuntimeProvider(client: online.client, cache: cache, bundledSnapshot: bundled)
        await provider.refresh()

        // The same provider with its server gone: it keeps the served config.
        let offline = APIRig(lan: { _ in .transportError() }, tailscale: { _ in .transportError() })
        let restarted = CameraRuntimeProvider(client: offline.client, cache: cache, bundledSnapshot: bundled)
        #expect(await restarted.refresh() == .cached)
        #expect(await restarted.currentRuntime().config == served)
        #expect(await restarted.refresh() == .cached)
    }

    @Test func aRefreshThatFindsOnlyTheSnapshotDoesNotReplaceAServedConfig() async {
        let flag = FlagBox()
        let rig = APIRig(lan: { request in
            if isProbe(request) { return .fixture("recipe_list") }
            return flag.isDown ? .transportError() : .http(status: 200, body: body(of: self.served))
        }, tailscale: { _ in .transportError() })
        let provider = CameraRuntimeProvider(
            client: rig.client, cache: InMemoryClientConfigCache(), bundledSnapshot: bundled)
        await provider.refresh()
        #expect(await provider.source == .served)
        flag.isDown = true
        _ = await provider.refresh()
        // The first refresh cached the body, so the answer is the cached copy, never the snapshot.
        #expect(await provider.currentRuntime().config == served)
    }

    @Test func aPlainRuntimeIsItsOwnSource() async {
        let runtime = CameraRuntime(config: bundled, sleeper: RecordingSleeper())
        #expect(await runtime.currentRuntime().config == bundled)
    }
}

private final class FlagBox: Sendable {
    private let down = Mutex(false)
    var isDown: Bool {
        get { down.withLock { $0 } }
        set { down.withLock { $0 = newValue } }
    }
}
