import FilmcaseKit
import Foundation
import Testing

@testable import Filmcase

private struct NoPathEvents: NetworkPathEvents {
    func pathChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@Suite struct AppEnvironmentTests {
    @Test func buildsWithInMemoryStores() async throws {
        let suite = "dev.filmcase.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let environment = AppEnvironment(
            tokenStore: InMemoryTokenStore(),
            pinStore: InMemoryPinStore(),
            pathEvents: NoPathEvents(),
            endpointSettings: EndpointSettings(defaults: defaults)
        )

        #expect(try await environment.tokenStore.token() == nil)
        #expect(await environment.endpoints.endpoints.isEmpty)
        #expect(await OnboardingState.needsOnboarding(in: environment))
    }
}
