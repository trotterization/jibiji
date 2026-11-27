import XCTest

final class InkReplacementUITests: XCTestCase {
    @MainActor
    func testReplaceEraseUndoAndRestoreAfterRelaunch() {
        continueAfterFailure = false
        var app = launch(reset: true)
        let canvas = app.descendants(matching: .any)["noteCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        draw(canvas, from: CGVector(dx: 0.30, dy: 0.30), to: CGVector(dx: 0.55, dy: 0.30))
        draw(canvas, from: CGVector(dx: 0.44, dy: 0.23), to: CGVector(dx: 0.32, dy: 0.42))
        draw(canvas, from: CGVector(dx: 0.43, dy: 0.30), to: CGVector(dx: 0.57, dy: 0.42))
        waitStatus("3 strokes · Saved", app)
        app.buttons["suggestButton"].tap()
        XCTAssertTrue(app.buttons["replaceHandwriting"].waitForExistence(timeout: 10))
        // The fixture does not say where each field is, so the whole line is replaced.
        app.buttons["replaceHandwriting"].tap()
        // Clean handwriting is written as several thin pen strokes.
        let replaced = waitReplaced(app)
        XCTAssertTrue(app.buttons["deleteReplacement"].exists)
        XCTAssertTrue(app.buttons["restoreReplacementInline"].exists, "Restore should sit right under the replacement")
        XCTAssertFalse(app.buttons["replaceHandwriting"].exists)
        app.buttons["Undo"].firstMatch.tap()
        waitStatus("3 strokes · Saved", app)
        app.buttons["Redo"].firstMatch.tap()
        waitStatus(replaced, app)
        // Sizing keeps the same strokes and the chip, and is one undo step.
        XCTAssertTrue(app.buttons["growReplacement"].waitForExistence(timeout: 5))
        app.buttons["growReplacement"].tap()
        app.buttons["shrinkReplacement"].tap()
        waitStatus(replaced, app)
        XCTAssertTrue(app.buttons["restoreReplacementInline"].exists)
        app.buttons["deleteReplacement"].tap()
        waitStatus("0 strokes · Saved", app)
        app.buttons["Undo"].firstMatch.tap()
        waitStatus(replaced, app)
        app.terminate()
        app = launch(reset: false)
        waitStatus(replaced, app)
        XCTAssertTrue(app.buttons["undoSuggestion"].waitForExistence(timeout: 5))
        app.buttons["undoSuggestion"].tap()
        waitStatus("3 strokes · Saved", app)
    }

    /// Issue #29: the student's strokes stay and only what is missing is added.
    @MainActor
    func testReplaceInPlaceKeepsTheInkAndCanBeUndoneAndRestoredAfterRelaunch() {
        continueAfterFailure = false
        var app = launch(reset: true, inPlace: true)
        let canvas = app.descendants(matching: .any)["noteCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        draw(canvas, from: CGVector(dx: 0.15, dy: 0.30), to: CGVector(dx: 0.27, dy: 0.30))
        draw(canvas, from: CGVector(dx: 0.21, dy: 0.25), to: CGVector(dx: 0.16, dy: 0.38))
        draw(canvas, from: CGVector(dx: 0.21, dy: 0.30), to: CGVector(dx: 0.27, dy: 0.38))
        waitStatus("3 strokes · Saved", app)
        app.buttons["suggestButton"].tap()
        XCTAssertTrue(app.buttons["replaceHandwriting"].waitForExistence(timeout: 10))
        app.buttons["replaceHandwriting"].tap()
        let completed = waitReplaced(app)
        XCTAssertTrue(app.buttons["restoreReplacementInline"].waitForExistence(timeout: 5))
        // What was added belongs where it is: it can be taken back, not resized or deleted on its own.
        XCTAssertFalse(app.buttons["growReplacement"].exists)
        XCTAssertFalse(app.buttons["deleteReplacementInline"].exists)
        app.buttons["Undo"].firstMatch.tap()
        waitStatus("3 strokes · Saved", app)
        app.buttons["Redo"].firstMatch.tap()
        waitStatus(completed, app)
        // Asking again has nothing new to say about a completed note.
        app.buttons["suggestButton"].tap()
        XCTAssertFalse(app.buttons["replaceHandwriting"].waitForExistence(timeout: 3))
        app.terminate()
        app = launch(reset: false, inPlace: true)
        waitStatus(completed, app)
        XCTAssertTrue(app.buttons["undoSuggestion"].waitForExistence(timeout: 5))
        app.buttons["undoSuggestion"].tap()
        waitStatus("3 strokes · Saved", app)
    }

    @MainActor private func launch(reset: Bool, inPlace: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-ink-replacement", "-JIBIJIReplacementFixture", "YES"]
        if inPlace { app.launchArguments += ["-JIBIJIInPlaceFixture", "YES"] }
        if reset { app.launchArguments += ["-JIBIJIResetStore", "YES"] }
        app.launch()
        XCTAssertTrue(app.buttons["openNotebook"].waitForExistence(timeout: 10))
        app.buttons["openNotebook"].tap()
        let resume = app.buttons["continueWriting"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "The home page didn't appear")
        resume.tap()
        return app
    }

    @MainActor private func draw(_ canvas: XCUIElement, from: CGVector, to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: to))
    }

    /// Waits for the page to save after a replacement and returns its status line.
    @MainActor private func waitReplaced(_ app: XCUIApplication) -> String {
        let match = NSPredicate(format: "label ENDSWITH %@ AND NOT (label BEGINSWITH %@)", "strokes · Saved", "3 strokes")
        expectation(for: match, evaluatedWith: app.staticTexts["pageStatus"])
        waitForExpectations(timeout: 10)
        return app.staticTexts["pageStatus"].label
    }

    @MainActor private func waitStatus(_ text: String, _ app: XCUIApplication) {
        let match = NSPredicate(format: "label == %@", text)
        expectation(for: match, evaluatedWith: app.staticTexts["pageStatus"])
        waitForExpectations(timeout: 10)
    }
}
