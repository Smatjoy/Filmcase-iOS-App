import XCTest

/// CI smoke test on the demo flavour: no server, no camera, no onboarding.
final class FilmcaseUITests: XCTestCase {
    @MainActor
    func testFirstRecipeShowsSpecSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let firstRecipe = app.cells.firstMatch
        XCTAssertTrue(firstRecipe.waitForExistence(timeout: 20), "The recipe list never loaded")
        firstRecipe.tap()

        XCTAssertTrue(
            app.staticTexts["Film Simulation"].firstMatch.waitForExistence(timeout: 20),
            "The spec sheet does not show Film Simulation")
    }
}
