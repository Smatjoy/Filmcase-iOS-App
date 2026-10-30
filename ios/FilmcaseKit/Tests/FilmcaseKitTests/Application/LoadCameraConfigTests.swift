import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

private func body(of config: ClientConfig) -> Data { try! JSONEncoder().encode(config) }

private func serving(_ data: Data) -> @Sendable (URLRequest) -> StubReply {
    { request in isProbe(request) ? .fixture("recipe_list") : .http(status: 200, body: data) }
}

@Suite("loadClientConfig")
struct LoadCameraConfigTests {
    private let bundled = try! TestSupport.makeConfig(["CAMERA_MAX_RETRIES": 1])
    private let served = try! TestSupport.makeConfig(["CAMERA_MAX_RETRIES": 5])
    private let cachedConfig = try! TestSupport.makeConfig(["CAMERA_MAX_RETRIES": 3])

    @Test func theServedConfigWinsAndIsCached() async throws {
        let rig = APIRig(lan: serving(body(of: served)))
        let cache = InMemoryClientConfigCache(data: body(of: cachedConfig))
        let result = await loadClientConfig(client: rig.client, cache: cache, bundledSnapshot: bundled)
        #expect(result.source == .served)
        #expect(result.config == served)
        #expect(try JSONDecoder().decode(ClientConfig.self, from: try #require(await cache.load())) == served)
    }

    @Test func theRealServedBodyDecodes() async {
        let rig = APIRig(lan: serving(Fixture.data("camera_client_config")))
        let result = await loadClientConfig(
            client: rig.client, cache: InMemoryClientConfigCache(), bundledSnapshot: bundled)
        #expect(result.source == .served)
        #expect(result.config.encodings == TestSupport.encodings)
    }

    @Test func anUnreachableServerFallsBackToTheCache() async {
        let rig = APIRig(lan: { _ in .transportError() }, tailscale: { _ in .transportError() })
        let cache = InMemoryClientConfigCache(data: body(of: cachedConfig))
        let result = await loadClientConfig(client: rig.client, cache: cache, bundledSnapshot: bundled)
        #expect(result.source == .cached)
        #expect(result.config == cachedConfig)
    }

    @Test func noServerAndNoCacheFallsBackToTheBundledSnapshot() async {
        let rig = APIRig(lan: { _ in .transportError() }, tailscale: { _ in .transportError() })
        let result = await loadClientConfig(
            client: rig.client, cache: InMemoryClientConfigCache(), bundledSnapshot: bundled)
        #expect(result.source == .bundled)
        #expect(result.config == bundled)
    }

    @Test func aRejectedTokenFallsBack() async {
        let rig = APIRig(lan: { request in
            isProbe(request) ? .fixture("recipe_list") : .fixture("error_401", status: 401)
        })
        let result = await loadClientConfig(
            client: rig.client, cache: InMemoryClientConfigCache(), bundledSnapshot: bundled)
        #expect(result.source == .bundled)
    }

    @Test func aBodyThatDoesNotDecodeIsNotCachedAndFallsBack() async {
        let rig = APIRig(lan: serving(Data("{\"settings\":1}".utf8)))
        let cache = InMemoryClientConfigCache(data: body(of: cachedConfig))
        let result = await loadClientConfig(client: rig.client, cache: cache, bundledSnapshot: bundled)
        #expect(result.source == .cached)
        let stored = try? JSONDecoder().decode(ClientConfig.self, from: await cache.load() ?? Data())
        #expect(stored == cachedConfig, "the bad body must not replace the cache")
    }

    @Test func aCorruptCacheIsSkipped() async {
        let rig = APIRig(lan: { _ in .transportError() }, tailscale: { _ in .transportError() })
        let result = await loadClientConfig(
            client: rig.client, cache: InMemoryClientConfigCache(data: Data("nope".utf8)), bundledSnapshot: bundled)
        #expect(result.source == .bundled)
    }
}

@Suite("Bundled client-config snapshot")
struct BundledSnapshotTests {
    private static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // file -> Application -> FilmcaseKitTests -> Tests -> FilmcaseKit -> ios -> repo root
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    private func encodings(in url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try #require(object as? [String: Any])
        return try #require(root["encodings"] as? [String: Any])
    }

    @Test func theAppSnapshotHasTheEncodingsTheGoldenVectorsDo() throws {
        let snapshot = Self.repoRoot.appendingPathComponent("ios/App/Demo/Fixtures/camera_client_config.json")
        let vectors = Self.repoRoot.appendingPathComponent("tests/fixtures/camera/recipe_ptp_vectors.json")
        let bundled = try encodings(in: snapshot)
        let golden = try encodings(in: vectors)
        #expect(
            NSDictionary(dictionary: bundled).isEqual(to: golden),
            """
            ios/App/Demo/Fixtures/camera_client_config.json is stale: its "encodings" differ from \
            tests/fixtures/camera/recipe_ptp_vectors.json. Re-copy the snapshot from \
            GET /api/v1/camera/client-config.json into ios/App/Demo/Fixtures/ (and the same file into \
            ios/FilmcaseKit/Tests/FilmcaseKitTests/API/Fixtures/).
            """)
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: Data(contentsOf: snapshot))
        #expect(decoded.encodings == TestSupport.encodings)
    }
}
