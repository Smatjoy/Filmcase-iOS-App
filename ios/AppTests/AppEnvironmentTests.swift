import FilmcaseKit
import Foundation
import Testing

@testable import Filmcase

@MainActor
@Suite struct AppEnvironmentTests {
    @Test func buildsWithInMemoryStores() async throws {
        let suite = "dev.filmcase.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let environment = AppEnvironment(
            tokenStore: InMemoryTokenStore(),
            pinStore: InMemoryPinStore(),
            pathEvents: IdlePathEvents(),
            endpointSettings: EndpointSettings(defaults: defaults),
            cameraMode: .usb
        )

        #expect(try await environment.tokenStore.token() == nil)
        #expect(await environment.endpoints.endpoints.isEmpty)
        #expect(await environment.needsOnboarding())
    }

    @Test func demoServesBundledRecipesAndSkipsOnboarding() async throws {
        let environment = AppEnvironment.demo()

        #expect(await environment.needsOnboarding() == false)
        let page = try await environment.client.recipes()
        #expect(!page.results.isEmpty)
    }

    @Test func demoCameraReadsSevenNamedSlots() async throws {
        let environment = AppEnvironment.demo()
        await environment.cameraModel.connect()
        let observer = Task { await environment.cameraModel.observe() }
        defer { observer.cancel() }

        for _ in 0..<200 where environment.cameraModel.slots.count < 7 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(environment.cameraModel.slots.map(\.name).count == 7)
        #expect(!environment.cameraModel.slots.contains { $0.name.isEmpty })
    }

    @Test func launchArgumentSelectsDemo() {
        let environment = AppEnvironment.launch(arguments: ["Filmcase", "-demo"])
        #expect(environment.cameraMode == .demo)
    }
}
