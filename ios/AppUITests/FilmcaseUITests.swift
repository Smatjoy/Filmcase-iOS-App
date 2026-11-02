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

    // MARK: Accessibility audits (docs/ios_accessibility_audit.md)

    /// Apple's automated audit (contrast, hit regions, clipped text, Dynamic Type, missing
    /// descriptions, traits) on the demo recipes list. It covers only what a machine can see;
    /// the VoiceOver checklist in the audit document still needs a person with a device.
    @MainActor
    func testRecipeListPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 20), "The recipe list never loaded")

        // API: XCUIApplication.performAccessibilityAudit(for:_:) (iOS 17). No issue types are
        // excluded: if CI reports a false positive, exclude that one type here with a comment
        // naming the element, and record it in the audit document.
        try app.performAccessibilityAudit()
    }

    @MainActor
    func testRecipeDetailPassesAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let firstRecipe = app.cells.firstMatch
        XCTAssertTrue(firstRecipe.waitForExistence(timeout: 20), "The recipe list never loaded")
        firstRecipe.tap()
        XCTAssertTrue(
            app.staticTexts["Film Simulation"].firstMatch.waitForExistence(timeout: 20),
            "The spec sheet does not show Film Simulation")

        try app.performAccessibilityAudit()
    }
}
