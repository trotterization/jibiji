import XCTest

/// Opt-in physical-iPad regression on the existing synthetic replay notebook.
/// Acceptance replaces ink; Restore must return the seeded page unchanged.
final class InlineSuggestionDeviceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["JIBIJI_M2_DEVICE_UI"] == "1" else {
            throw XCTSkip("Opt-in physical-iPad replay: TEST_RUNNER_JIBIJI_M2_DEVICE_UI=1")
        }
    }

    @MainActor
    func testReviewSkipReplaceAndRestoreOriginalInk() {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-m2-replay"]
        app.launch()
        XCTAssertTrue(app.buttons["openNotebook"].waitForExistence(timeout: 10))
        app.buttons["openNotebook"].tap()
        let resume = app.buttons["continueWriting"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "The home page didn't appear")
        resume.tap()
        // Restore an accepted replacement from an interrupted previous replay.
        if app.buttons["undoSuggestion"].exists { app.buttons["undoSuggestion"].tap() }
        let originalStatus = app.staticTexts["pageStatus"].label
        app.buttons["suggestButton"].tap()
        XCTAssertTrue(app.buttons["replaceHandwriting"].waitForExistence(timeout: 30))
        // Skip every suggestion: the page must be unchanged.
        while app.buttons["suggestionOptions"].firstMatch.exists {
            app.buttons["suggestionOptions"].firstMatch.tap()
            XCTAssertTrue(app.buttons["skipSuggestion"].waitForExistence(timeout: 5))
            app.buttons["skipSuggestion"].tap()
        }
        XCTAssertEqual(app.staticTexts["pageStatus"].label, originalStatus)
        app.buttons["suggestButton"].tap()
        XCTAssertTrue(app.buttons["replaceHandwriting"].waitForExistence(timeout: 30))
        app.buttons["replaceHandwriting"].firstMatch.tap()
        XCTAssertTrue(app.buttons["undoSuggestion"].waitForExistence(timeout: 5))
        app.buttons["undoSuggestion"].tap()
        let restored = NSPredicate(format: "label == %@", originalStatus)
        expectation(for: restored, evaluatedWith: app.staticTexts["pageStatus"])
        waitForExpectations(timeout: 10)
    }
}
