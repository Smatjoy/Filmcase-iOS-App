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

        // Two passes so every row is checked for contrast at least once away from the bottom
        // chrome: rows ignored in the fade band on the first pass are mid-screen on the second.
        try audit(app, fadeBand: 64)
        app.scrollViews.firstMatch.swipeUp()
        try audit(app, fadeBand: 0)
    }

    /// Apple's audit with exactly two known false positives ignored, both recorded in
    /// docs/ios_accessibility_audit.md; every other issue fails the test.
    /// - Contrast on elements under the tab bar or its bottom accessory (both measured from
    ///   their own frames), or within *fadeBand* points above them, where iOS 26's soft
    ///   scroll-edge effect fades scrolling content. The audit measures that faded text, so
    ///   full-primary spec-sheet rows were reported. A caller that ignores a band audits
    ///   again after scrolling, so those rows are still checked mid-screen.
    /// - Clipped text in the system search field: its placeholder is drawn by UIKit, not us.
    @MainActor
    private func audit(_ app: XCUIApplication, fadeBand: CGFloat = 0) throws {
        // The top of the bottom chrome, measured rather than guessed: the bottom accessory
        // is our own connection pill ("Camera connection"), and the tab bar sits below it.
        // With neither found, nothing is ignored.
        let chromeFrames = [app.tabBars.firstMatch, app.buttons["Camera connection"].firstMatch]
            .filter(\.exists)
            .map(\.frame)
        // 12 pt for the accessory's glass capsule, which is a little taller than the button.
        let chromeTop = (chromeFrames.map(\.minY).min() ?? .greatestFiniteMagnitude) - 12 - fadeBand

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
