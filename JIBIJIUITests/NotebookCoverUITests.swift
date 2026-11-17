import XCTest

final class NotebookCoverUITests: XCTestCase {
    @MainActor
    func testCoverOpensNotebookAndCanBeReopened() {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-cover", "-JIBIJIResetStore", "YES"]
        app.launch()
        let open = app.buttons["openNotebook"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["noteCanvas"].exists)
        open.tap()
        XCTAssertTrue(app.staticTexts["pageStatus"].waitForExistence(timeout: 10))
        app.buttons["showCover"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.staticTexts["pageStatus"].waitForExistence(timeout: 10))
    }
}
