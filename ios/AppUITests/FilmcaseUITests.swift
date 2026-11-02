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
    /// - Contrast on elements that extend under the tab bar and its bottom accessory: the
    ///   audit measures them against the translucent bar instead of the page, so primary text
    ///   in the lower spec-sheet rows was reported although it is full primary on the page.
    /// - Clipped text in the system search field: its placeholder is drawn by UIKit, not us.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        // The bar plus the bottom accessory above it (about 60 pt); the bottom 160 pt if the
        // bar cannot be found.
        let chromeTop = tabBar.exists ? tabBar.frame.minY - 60 : window.maxY - 160

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
