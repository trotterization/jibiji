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
        // Another reading is picked from the chip's menu; Replace then writes it in place.
        app.buttons["suggestionOptions"].tap()
        XCTAssertTrue(app.buttons["牛"].waitForExistence(timeout: 5))
        app.buttons["牛"].tap()
        app.buttons["replaceHandwriting"].tap()
        waitStatus("1 stroke · Saved", app)
        XCTAssertTrue(app.buttons["deleteReplacement"].exists)
        XCTAssertTrue(app.buttons["restoreReplacementInline"].exists, "Restore should sit right under the replacement")
        XCTAssertFalse(app.buttons["replaceHandwriting"].exists)
        app.buttons["Undo"].firstMatch.tap()
        waitStatus("3 strokes · Saved", app)
        app.buttons["Redo"].firstMatch.tap()
        waitStatus("1 stroke · Saved", app)
        app.buttons["deleteReplacement"].tap()
        waitStatus("0 strokes · Saved", app)
        app.buttons["Undo"].firstMatch.tap()
        waitStatus("1 stroke · Saved", app)
        app.terminate()
        app = launch(reset: false)
        waitStatus("1 stroke · Saved", app)
        XCTAssertTrue(app.buttons["undoSuggestion"].waitForExistence(timeout: 5))
        app.buttons["undoSuggestion"].tap()
        waitStatus("3 strokes · Saved", app)
    }

    @MainActor private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-ink-replacement", "-JIBIJIReplacementFixture", "YES"]
        if reset { app.launchArguments += ["-JIBIJIResetStore", "YES"] }
        app.launch()
        XCTAssertTrue(app.buttons["openNotebook"].waitForExistence(timeout: 10))
        app.buttons["openNotebook"].tap()
        return app
    }

    @MainActor private func draw(_ canvas: XCUIElement, from: CGVector, to: CGVector) {
        canvas.coordinate(withNormalizedOffset: from).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: to))
    }

    @MainActor private func waitStatus(_ text: String, _ app: XCUIApplication) {
        let match = NSPredicate(format: "label == %@", text)
        expectation(for: match, evaluatedWith: app.staticTexts["pageStatus"])
        waitForExpectations(timeout: 10)
    }
}
