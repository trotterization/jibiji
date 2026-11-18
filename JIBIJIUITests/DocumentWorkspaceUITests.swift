import XCTest

final class DocumentWorkspaceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testReadingModeProtectsInkAndWritingCanResume() {
        let app = home("reading-mode", reset: true)
        app.buttons["continueWriting"].tap()
        let mode = app.buttons["pageReadingMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        draw(app.windows.firstMatch, y: 0.38)
        waitLabel("1 stroke · Saved", app.staticTexts["pageStatus"])
        mode.tap()
        XCTAssertTrue(mode.label.contains("Write"))
        draw(app.windows.firstMatch, y: 0.5)
        XCTAssertEqual(app.staticTexts["pageStatus"].label, "1 stroke · Saved")
        attach(app, "Reading mode")
        mode.tap()
        XCTAssertTrue(mode.label.contains("Read"))
        draw(app.windows.firstMatch, y: 0.5)
        waitLabel("2 strokes · Saved", app.staticTexts["pageStatus"])
    }

    @MainActor func testPDFTextSearchAnnotationAndRelaunch() {
        var app = home("pdf-workspace", reset: true)
        openPDF(app)
        let mode = app.buttons["pdfReadingMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        XCTAssertTrue(mode.label.contains("Write"))
        let search = app.textFields["pdfSearch"]
        search.tap(); search.typeText("Mandarin")
        waitLabel("1/2", app.staticTexts["pdfSearchCount"])
        mode.tap()
        XCTAssertTrue(mode.label.contains("Read"))
        let canvas = app.descendants(matching: .any)["pdfCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        attach(app, "PDF writing mode")
        draw(app.windows.firstMatch, y: 0.4)
        let status = app.staticTexts["pdfSaveStatus"]
        waitValue("1 annotation strokes", status)
        mode.tap()
        attach(app, "PDF reading and annotation")
        app.terminate()
        app = home("pdf-workspace", reset: false)
        openPDF(app)
        XCTAssertTrue(app.buttons["pdfReadingMode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pdfReadingMode"].label.contains("Write"))
        waitValue("1 annotation strokes", app.staticTexts["pdfSaveStatus"])
        attach(app, "PDF annotations after relaunch")
    }

    @MainActor func testScannedPDFSearchAndHighlightSurviveRelaunch() {
        var app = home("scanned-pdf", reset: true, scanned: true)
        app.buttons["openPDFLibrary"].tap()
        let document = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfDocument-")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("orchid")
        XCTAssertTrue(document.waitForExistence(timeout: 45))
        document.tap()
        let field = app.textFields["pdfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("orchid")
        waitLabel("1/1", app.staticTexts["pdfSearchCount"], timeout: 45)
        attach(app, "Scanned PDF OCR highlight")
        app.terminate()
        app = home("scanned-pdf", reset: false, scanned: true)
        openPDF(app)
        let reopened = app.textFields["pdfSearch"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        reopened.tap(); reopened.typeText("laboratory")
        waitLabel("1/1", app.staticTexts["pdfSearchCount"], timeout: 20)
        attach(app, "Scanned PDF cached search")
    }

    @MainActor private func home(_ name: String, reset: Bool, scanned: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-\(name)", "-JIBIJIPDFFixture", "YES"]
        if scanned { app.launchArguments += ["-JIBIJIScannedPDFFixture", "YES"] }
        if reset { app.launchArguments += ["-JIBIJIResetStore", "YES"] }
        app.launch()
        XCTAssertTrue(app.buttons["openNotebook"].waitForExistence(timeout: 10))
        app.buttons["openNotebook"].tap()
        XCTAssertTrue(app.buttons["continueWriting"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func openPDF(_ app: XCUIApplication) {
        app.buttons["openPDFLibrary"].tap()
        let document = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pdfDocument-")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        document.tap()
    }
    @MainActor private func draw(_ view: XCUIElement, y: CGFloat) {
        view.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y)).press(forDuration: 0.1, thenDragTo: view.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: y)))
    }
    @MainActor private func waitLabel(_ value: String, _ element: XCUIElement, timeout: TimeInterval = 15) {
        let predicate = NSPredicate(format: "label == %@", value)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed, element.debugDescription)
    }
    @MainActor private func waitValue(_ value: String, _ element: XCUIElement) {
        let predicate = NSPredicate(format: "value == %@", value)
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 15) == .completed, element.debugDescription)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
