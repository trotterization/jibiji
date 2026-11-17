import XCTest

final class PaddlePipelineUITests: XCTestCase {
    @MainActor
    func testRecognitionComparisonIsAvailableWithoutChangingTheDefaultEngine() {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-paddle-preview", "-JIBIJIResetStore", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["openNotebook"].waitForExistence(timeout: 10))
        app.buttons["openNotebook"].tap()
        let resume = app.buttons["continueWriting"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "The home page didn't appear")
        resume.tap()
        XCTAssertTrue(app.buttons["Check recognition"].waitForExistence(timeout: 10))
        app.buttons["Check recognition"].tap()
        let compare = app.buttons["comparePaddlePipeline"]
        // The form can scroll: keep the comparison control reachable on small tablet windows.
        for _ in 0..<4 where !compare.isHittable { app.swipeUp() }
        XCTAssertTrue(compare.waitForExistence(timeout: 10))
        compare.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "No confident reading found.")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["usePaddlePipeline"].exists)
    }
}
