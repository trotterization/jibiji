import XCTest

final class NotebookCoverUITests: XCTestCase {
    @MainActor
    func testCoverOpensHomeThenPageAndBack() {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-cover", "-JIBIJIResetStore", "YES"]
        app.launch()
        let open = app.buttons["openNotebook"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["noteCanvas"].exists)
        open.tap()
        let resume = app.buttons["continueWriting"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "Opening the notebook should show its home page")
        XCTAssertTrue(app.buttons["homePage-page-1"].exists)
        resume.tap()
        XCTAssertTrue(app.staticTexts["pageStatus"].waitForExistence(timeout: 10))
        app.buttons["showHome"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        app.buttons["showCover"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
    }

    @MainActor
    func testHomeNamesPinsAndFilesPagesAndKeepsThemAfterRelaunch() {
        var app = launchHome(reset: true)
        // A second page, made from the home page.
        app.buttons["homeNewPage"].tap()
        XCTAssertTrue(app.staticTexts["pageTitle"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["pageTitle"].label, "Page 2")
        app.buttons["showHome"].tap()
        let second = app.buttons["homePage-page-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))

        // Rename it.
        second.press(forDuration: 1.2)
        tapMenuItem("Rename…", in: app)
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Lesson 5")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Lesson 5"].waitForExistence(timeout: 5), "The page should show its new name")

        // Pin it.
        app.buttons["homePage-page-2"].press(forDuration: 1.2)
        tapMenuItem("Pin", in: app)
        XCTAssertTrue(app.buttons["filter-pinned"].waitForExistence(timeout: 5))

        // A folder, from the folder chips.
        app.buttons["homeNewFolder"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Grammar")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["folder-Grammar"].waitForExistence(timeout: 5))

        // The page bar uses the name too.
        app.buttons["filter-all"].tap()
        app.buttons["homePage-page-2"].tap()
        XCTAssertTrue(app.staticTexts["pageTitle"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["pageTitle"].label, "Lesson 5")

        app.terminate()
        app = launchHome(reset: false)
        XCTAssertTrue(app.buttons["Lesson 5"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["filter-pinned"].exists)
        XCTAssertTrue(app.buttons["folder-Grammar"].exists)
    }

    @MainActor private func launchHome(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-home"]
        if reset { app.launchArguments += ["-JIBIJIResetStore", "YES"] }
        app.launch()
        let open = app.buttons["openNotebook"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["continueWriting"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func tapMenuItem(_ title: String, in app: XCUIApplication) {
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(title) in the page menu")
        item.tap()
    }
}
