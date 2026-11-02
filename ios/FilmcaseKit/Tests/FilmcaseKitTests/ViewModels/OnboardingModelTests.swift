import Foundation
import Synchronization
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FilmcaseKit

/// Stands in for the app's pinning transport: a host with no pin throws `UnpinnedHostError`
/// carrying *fingerprint*; a host with a different pin throws `PinMismatchError`.
struct PinCheckingTransport: HTTPTransport {
    let inner: any HTTPTransport
    let evaluator: TrustEvaluator
    let fingerprint: String

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url?.host() ?? ""
        switch try await evaluator.evaluate(host: host, presentedFingerprintSHA256Hex: fingerprint) {
        case .trusted: return try await inner.send(request)
        case .unpinned(let fingerprint): throw UnpinnedHostError(host: host, fingerprint: fingerprint)
        case .mismatch: throw PinMismatchError(host: host)
        }
    }
}

@MainActor
private struct OnboardingRig {
    let server: StubServer
    let tokenStore = InMemoryTokenStore()
    let pins = InMemoryPinStore()
    let settings = InMemoryEndpointSettingsStore()
    let trust: TrustEvaluator
    let endpoints: ServerEndpoints
    let model: OnboardingModel

    static let fingerprint = "aabbccdd0011"

    init(
        pinned: Bool = true, presentedFingerprint: String = OnboardingRig.fingerprint,
        savedURLs: [URL] = [], handler: @escaping @Sendable (URLRequest) -> StubReply = { _ in .fixture("recipe_list") }
    ) {
        server = StubServer(name: "onboarding", handler: handler)
        trust = TrustEvaluator(store: pins)
        if pinned { pins.setFingerprint(Self.fingerprint, for: server.host) }
        settings.save(savedURLs)
        let transport = PinCheckingTransport(
            inner: StubRegistry.makeSession(), evaluator: trust, fingerprint: presentedFingerprint)
        endpoints = ServerEndpoints(endpoints: savedURLs, transport: transport, clock: TestClock())
        let client = FilmcaseClient(endpoints: endpoints, tokenStore: tokenStore, transport: transport)
        model = OnboardingModel(
            tokenStore: tokenStore, endpoints: endpoints, client: client, trust: trust, settings: settings)
    }

    func fill(token: String = "secret") {
        model.lanURL = server.baseURL.absoluteString
        model.token = token
    }
}

@MainActor
@Suite("OnboardingModel")
struct OnboardingModelTests {
    // --- validation ---

    @Test func anEmptyFormNamesEveryMissingField() {
        let rig = OnboardingRig()
        #expect(rig.model.validate() == nil)
        #expect(rig.model.lanURLError == "Enter at least one server URL.")
        #expect(rig.model.tailscaleURLError == nil)
    }

    @Test func theTokenIsOptional() {
        let rig = OnboardingRig()
        rig.model.lanURL = "https://filmcase.lan"
        #expect(rig.model.validate() == [URL(string: "https://filmcase.lan")!])
    }

    @Test(arguments: [
        ("http://filmcase.lan", "Only https:// addresses are supported."),
        ("filmcase.lan", "Start the address with https://"),
        ("ftp://filmcase.lan", "Only https:// addresses are supported."),
        ("https://", "Enter a full address such as https://filmcase.lan"),
        ("https://film case.lan", "That does not look like a valid address."),
    ])
    func aBadLANURLIsExplained(text: String, message: String) {
        let rig = OnboardingRig()
        rig.model.lanURL = text
        rig.model.token = "t"
        #expect(rig.model.validate() == nil)
        #expect(rig.model.lanURLError == message)
    }

    @Test func eachURLFieldGetsItsOwnMessage() {
        let rig = OnboardingRig()
        rig.model.lanURL = "http://a.lan"
        rig.model.tailscaleURL = "b.ts.net"
        rig.model.token = "t"
        #expect(rig.model.validate() == nil)
        #expect(rig.model.lanURLError == "Only https:// addresses are supported.")
        #expect(rig.model.tailscaleURLError == "Start the address with https://")
    }

    @Test func oneURLIsEnoughAndLANComesFirst() {
        let rig = OnboardingRig()
        rig.model.tailscaleURL = "  https://filmcase.tail.ts.net  "
        rig.model.token = " t "
        #expect(rig.model.validate() == [URL(string: "https://filmcase.tail.ts.net")!])

        rig.model.lanURL = "HTTPS://filmcase.lan"
        #expect(rig.model.validate()?.map { $0.host() } == ["filmcase.lan", "filmcase.tail.ts.net"])
    }

    @Test func editingAFieldClearsItsMessage() {
        let rig = OnboardingRig()
        rig.model.validate()
        #expect(rig.model.lanURLError != nil)
        rig.model.lanURL = "h"
        #expect(rig.model.lanURLError == nil)
    }

    @Test func aBadFormNeverReachesTheNetwork() async {
        let rig = OnboardingRig()
        rig.model.lanURL = "http://insecure.lan"
        rig.model.token = "t"
        await rig.model.connect()
        #expect(rig.model.state == .idle)
        #expect(rig.server.requests.isEmpty)
        #expect(await rig.tokenStore.token() == nil)
    }

    // --- connecting ---

    @Test func savedURLsFillTheFormAndFinishedOnboardingIsRecognised() async throws {
        let urls = [URL(string: "https://a.lan")!, URL(string: "https://b.ts.net")!]
        let rig = OnboardingRig(savedURLs: urls)
        #expect(rig.model.lanURL == "https://a.lan")
        #expect(rig.model.tailscaleURL == "https://b.ts.net")
        #expect(await rig.tokenStore.token() == nil)
        #expect(await !OnboardingModel.needsOnboarding(endpoints: rig.endpoints))
        await rig.endpoints.update(endpoints: [])
        #expect(await OnboardingModel.needsOnboarding(endpoints: rig.endpoints))
    }

    @Test func connectingSavesEverythingThenReportsConnected() async throws {
        let rig = OnboardingRig()
        rig.fill(token: " secret ")
        await rig.model.connect()

        #expect(rig.model.state == .connected)
        #expect(await rig.tokenStore.token() == "secret")
        #expect(rig.settings.urls() == [rig.server.baseURL])
        #expect(await rig.endpoints.endpoints == [rig.server.baseURL])
        let authenticated = rig.server.authenticatedRequests
        #expect(authenticated.count == 1)
        #expect(authenticated.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test(arguments: [
        (401, "error_401", "The server rejected the token."),
        (503, "error_503", "The server has no API token configured."),
    ])
    func aServerRefusalIsShown(status: Int, fixture: String, message: String) async {
        let rig = OnboardingRig(handler: { _ in .fixture(fixture, status: status) })
        rig.fill()
        await rig.model.connect()
        #expect(rig.model.state == .failed(message))
    }

    @Test func nobodyAnsweringIsShown() async {
        let rig = OnboardingRig(handler: { _ in .transportError() })
        rig.fill()
        await rig.model.connect()
        #expect(rig.model.state == .failed(
            "No server answered. Check the URLs and that you are on the right network."))
    }

    @Test func aChangedCertificateIsReportedWithoutOfferingTrust() async {
        let rig = OnboardingRig(presentedFingerprint: "ffffffff")
        rig.fill()
        await rig.model.connect()
        #expect(rig.model.state == .failed(
            "The certificate for \(rig.server.host) changed since you trusted it."))
    }

    @Test func connectingAgainAfterAFailureCanSucceed() async {
        let answer = Answer()
        let rig = OnboardingRig(handler: { _ in answer.reply })
        answer.reply = .fixture("error_401", status: 401)
        rig.fill()
        await rig.model.connect()
        #expect(rig.model.state == .failed("The server rejected the token."))

        answer.reply = .fixture("recipe_list")
        await rig.model.connect()
        #expect(rig.model.state == .connected)
    }

    // --- trust on first use ---

    @Test func theSpokenFingerprintExistsOnlyWhileTrustIsAsked() async {
        let rig = OnboardingRig(pinned: false)
        rig.fill()
        #expect(rig.model.accessibilityFingerprint == nil)
        await rig.model.connect()
        #expect(rig.model.accessibilityFingerprint == "AA, BB, CC, DD, 00, 11")
        rig.model.cancelTrust()
        #expect(rig.model.accessibilityFingerprint == nil)
    }

    @Test func anUnpinnedHostIsShownForApprovalThenTrustedAndConnected() async throws {
        let rig = OnboardingRig(pinned: false)
        rig.fill()

        await rig.model.connect()
        #expect(rig.model.state == .needsTrust(host: rig.server.host, fingerprint: "AA:BB:CC:DD:00:11"))
        #expect(rig.pins.fingerprint(for: rig.server.host) == nil, "nothing is pinned until the person approves")
        #expect(rig.server.requests.isEmpty)

        await rig.model.trust()
        #expect(rig.model.state == .connected)
        #expect(rig.pins.fingerprint(for: rig.server.host) == OnboardingRig.fingerprint)
        #expect(rig.server.authenticatedRequests.count == 1)
        #expect(await rig.tokenStore.token() == "secret")
    }

    @Test func decliningTheFingerprintPinsNothingAndReturnsToTheForm() async {
        let rig = OnboardingRig(pinned: false)
        rig.fill()
        await rig.model.connect()
        rig.model.cancelTrust()
        #expect(rig.model.state == .idle)
        #expect(rig.pins.fingerprint(for: rig.server.host) == nil)

        await rig.model.trust()
        #expect(rig.model.state == .idle, "trust() without a pending fingerprint does nothing")
    }

    @Test func cancelTrustOutsideThePromptChangesNothing() async {
        let rig = OnboardingRig()
        rig.fill()
        await rig.model.connect()
        rig.model.cancelTrust()
        #expect(rig.model.state == .connected)
    }

    // --- fingerprints ---

    @Test(arguments: [
        ("aabbcc", "AA:BB:CC"),
        ("AA:bb:CC", "AA:BB:CC"),
        ("abc", "AB:C"),
        ("", ""),
    ])
    func fingerprintsAreColonSeparatedUppercasePairs(raw: String, expected: String) {
        #expect(OnboardingModel.formatted(fingerprint: raw) == expected)
    }
}

/// A reply a test can swap while the server is running.
private final class Answer: Sendable {
    private let current = Mutex<StubReply>(.fixture("recipe_list"))

    var reply: StubReply {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}
