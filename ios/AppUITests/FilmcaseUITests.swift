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

        try audit(app)
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

        try audit(app)
    }

    /// Apple's audit with exactly two known false positives ignored, both recorded in
    /// docs/ios_accessibility_audit.md; every other issue fails the test.
    /// - Contrast on elements that extend under the tab bar or its bottom accessory (both
    ///   measured from their own frames): the
    ///   audit measures them against the translucent bar instead of the page, so primary text
    ///   in the lower spec-sheet rows was reported although it is full primary on the page.
    /// - Clipped text in the system search field: its placeholder is drawn by UIKit, not us.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        // The top of the bottom chrome, measured rather than guessed: the bottom accessory
        // is our own connection pill ("Camera connection"), and the tab bar sits below it.
        // With neither found, nothing is ignored.
        let chromeFrames = [app.tabBars.firstMatch, app.buttons["Camera connection"].firstMatch]
            .filter(\.exists)
            .map(\.frame)
        // 12 pt for the accessory's glass capsule, which is a little taller than the button.
        let chromeTop = (chromeFrames.map(\.minY).min() ?? .greatestFiniteMagnitude) - 12

        // API: XCUIApplication.performAccessibilityAudit(for:_:) (iOS 17); returning true
        // from the handler ignores that issue.
        try app.performAccessibilityAudit { issue in
            guard let element = issue.element else { return false }
            switch issue.auditType {
            case .contrast:
                return element.frame.maxY > chromeTop
            case .textClipped:
                return element.elementType == .searchField
            default:
                return false
            }
        }
    }
}
