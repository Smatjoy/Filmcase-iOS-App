// Onboarding: the server URLs, the token, and the connect / trust-on-first-use flow.
// Everything the form decides lives here; the view renders `state` and the field errors.

import Foundation
import Observation

@MainActor
@Observable
public final class OnboardingModel {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        /// The host presented a certificate nobody has approved. *fingerprint* is formatted
        /// as colon-separated uppercase pairs for display.
        case needsTrust(host: String, fingerprint: String)
        case failed(String)
        case connected
    }

    public var lanURL: String {
        didSet { if lanURL != oldValue { lanURLError = nil } }
    }
    public var tailscaleURL: String {
        didSet { if tailscaleURL != oldValue { tailscaleURLError = nil } }
    }
    public var token = "" {
        didSet { if token != oldValue { tokenError = nil } }
    }

    public private(set) var state: State = .idle
    public private(set) var lanURLError: String?
    public private(set) var tailscaleURLError: String?
    public private(set) var tokenError: String?

    @ObservationIgnored private let tokenStore: any TokenStore
    @ObservationIgnored private let endpoints: ServerEndpoints
    @ObservationIgnored private let client: FilmcaseClient
    @ObservationIgnored private let trustEvaluator: TrustEvaluator
    @ObservationIgnored private let settings: any EndpointSettingsStore
    /// The fingerprint as the host presented it, kept raw for `approve`.
    @ObservationIgnored private var pendingFingerprint: String?

    public init(
        tokenStore: any TokenStore,
        endpoints: ServerEndpoints,
        client: FilmcaseClient,
        trust: TrustEvaluator,
        settings: any EndpointSettingsStore
    ) {
        self.tokenStore = tokenStore
        self.endpoints = endpoints
        self.client = client
        self.trustEvaluator = trust
        self.settings = settings
        let saved = settings.urls()
        lanURL = saved.first?.absoluteString ?? ""
        tailscaleURL = saved.count > 1 ? saved[1].absoluteString : ""
    }

    /// True when no token is stored or no server is configured.
    public static func needsOnboarding(tokenStore: any TokenStore, endpoints: ServerEndpoints) async -> Bool {
        let stored = (try? await tokenStore.token()) ?? nil
        let hasToken = !(stored ?? "").isEmpty
        let hasEndpoints = !(await endpoints.endpoints.isEmpty)
        return !(hasToken && hasEndpoints)
    }

    public var isConnecting: Bool { state == .connecting }

    // --- intents ---

    /// Validate the form, save it, then probe the server through the client.
    public func connect() async {
        guard state != .connecting else { return }
        guard let urls = validate() else { return }
        state = .connecting
        do {
            try await tokenStore.save(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            settings.save(urls)
            await endpoints.update(endpoints: urls)
            _ = try await client.recipes(page: 1, pageSize: 1)
            pendingFingerprint = nil
            state = .connected
        } catch FilmcaseClientError.unpinnedHost(let host, let fingerprint) {
            pendingFingerprint = fingerprint
            state = .needsTrust(host: host, fingerprint: Self.formatted(fingerprint: fingerprint))
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(UserMessages.text(for: error))
        }
    }

    /// The person approved the fingerprint shown: pin it, then connect again.
    public func trust() async {
        guard case .needsTrust(let host, _) = state, let fingerprint = pendingFingerprint else { return }
        do {
            try await trustEvaluator.approve(host: host, fingerprint: fingerprint)
        } catch {
            state = .failed(UserMessages.text(for: error))
            return
        }
        await connect()
    }

    public func cancelTrust() {
        guard case .needsTrust = state else { return }
        pendingFingerprint = nil
        state = .idle
    }

    // --- validation ---

    /// Check the form, recording a message per field. Returns the URLs (LAN first) when valid.
    @discardableResult
    public func validate() -> [URL]? {
        let lan = Self.parse(lanURL)
        let tailscale = Self.parse(tailscaleURL)
        lanURLError = lan.error
        tailscaleURLError = tailscale.error
        let urls = [lan.url, tailscale.url].compactMap { $0 }
        if lan.error == nil, tailscale.error == nil, urls.isEmpty {
            lanURLError = "Enter at least one server URL."
        }
        tokenError = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Enter the API token." : nil
        guard lanURLError == nil, tailscaleURLError == nil, tokenError == nil else { return nil }
        return urls
    }

    /// An empty field is fine (`url` and `error` both nil); anything else must be an https URL with a host.
    static func parse(_ text: String) -> (url: URL?, error: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (nil, nil) }
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else {
            return (nil, "That does not look like a valid address.")
        }
        guard let scheme = url.scheme?.lowercased() else {
            return (nil, "Start the address with https://")
        }
        guard scheme == "https" else {
            return (nil, "Only https:// addresses are supported.")
        }
        guard let host = url.host(), !host.isEmpty else {
            return (nil, "Enter a full address such as https://filmcase.lan")
        }
        return (url, nil)
    }

    /// "AB:CD:EF:..." from a bare (or already separated) hex string.
    public static func formatted(fingerprint: String) -> String {
        let characters = Array(fingerprint.uppercased().filter { $0 != ":" && !$0.isWhitespace })
        return stride(from: 0, to: characters.count, by: 2)
            .map { String(characters[$0..<min($0 + 2, characters.count)]) }
            .joined(separator: ":")
    }
}
