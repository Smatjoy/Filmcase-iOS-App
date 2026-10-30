import FilmcaseKit
import Foundation
import Observation

// TODO(P4c): move everything in this file except the SwiftUI bindings into FilmcaseKit
// (a tested onboarding view model): URL parsing, the connect/trust state machine and
// fingerprint formatting are decisions and belong under `swift test`.

@MainActor
@Observable
final class OnboardingState {
    enum Phase: Equatable {
        case editing
        case connecting
        /// The host answered with an unpinned certificate; ask the user.
        case awaitingTrust(host: String, fingerprint: String)
        case failed(String)
        case connected
    }

    var lanURL = ""
    var tailscaleURL = ""
    var token = ""
    private(set) var phase: Phase = .editing

    @ObservationIgnored private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// True when no token is stored or no endpoint is configured.
    static func needsOnboarding(in environment: AppEnvironment) async -> Bool {
        let hasToken = (try? await environment.tokenStore.token()) != nil
        let hasEndpoints = !(await environment.endpoints.endpoints.isEmpty)
        return !(hasToken && hasEndpoints)
    }

    /// Save the form, then probe: any answered request through the client reaches the server.
    func connect() async {
        phase = .connecting
        let urls = [lanURL, tailscaleURL]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
        guard !urls.isEmpty, !token.isEmpty else {
            phase = .failed("Enter at least one server URL and the API token.")
            return
        }
        do {
            try await environment.tokenStore.save(token: token)
            environment.endpointSettings.save(urls)
            await environment.endpoints.update(endpoints: urls)
            _ = try await environment.client.recipes(page: 1, pageSize: 1)
            phase = .connected
        } catch FilmcaseClientError.unpinnedHost(let host, let fingerprint) {
            phase = .awaitingTrust(host: host, fingerprint: fingerprint)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// The user approved the fingerprint shown: pin it, then probe again.
    func trustPresentedCertificate() async {
        guard case .awaitingTrust(let host, let fingerprint) = phase else { return }
        do {
            try await environment.trust.approve(host: host, fingerprint: fingerprint)
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }
        await connect()
    }

    func cancelTrust() {
        phase = .editing
    }

    /// "ab:cd:ef:..." from a bare hex string.
    static func formatted(fingerprint: String) -> String {
        let characters = Array(fingerprint.uppercased())
        return stride(from: 0, to: characters.count, by: 2)
            .map { String(characters[$0..<min($0 + 2, characters.count)]) }
            .joined(separator: ":")
    }

    private static func message(for error: any Error) -> String {
        switch error as? FilmcaseClientError {
        case .unauthorized: "The server rejected the token."
        case .serverNotConfigured: "The server has no API token configured."
        case .pinMismatch(let host): "The certificate for \(host) changed since you trusted it."
        case .noReachableServer: "No server answered. Check the URLs and that you are on the right network."
        default: String(describing: error)
        }
    }
}
