import XCTest

final class HomePersonalizationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testVisiblePageEditorSavesDetailsAndSurvivesRelaunch() {
        var app = home("page-details", reset: true)
        app.buttons["editPageDetails-page-1"].tap()
        let title = app.textFields["pageDetailsTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Lesson 8")
        let description = app.descendants(matching: .any)["pageDetailsDescription"].firstMatch
        description.tap(); description.typeText("Travel vocabulary")
        let pinned = app.switches["pageDetailsPinned"]
        pinned.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(pinned.value as? String, "1")
        attach(app, "Page details editor")
        app.buttons["savePageDetails"].tap()
        XCTAssertTrue(app.buttons["homePage-page-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["homePage-page-1"].label, "Lesson 8")
        XCTAssertTrue(app.staticTexts["Travel vocabulary"].exists)
        XCTAssertTrue(app.staticTexts["PINNED"].exists)
        app.terminate()
        app = home("page-details", reset: false)
        XCTAssertEqual(app.buttons["homePage-page-1"].label, "Lesson 8")
        XCTAssertTrue(app.staticTexts["Travel vocabulary"].exists)
        attach(app, "Personalized home")
    }

    @MainActor
    func testBackgroundAdjustmentsPersistAndCanReturnToAutomatic() {
        var app = home("background", reset: true)
        app.buttons["homeBackgroundButton"].tap()
        let automatic = app.switches["automaticHomeBackground"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "1")
        let blur = app.sliders["homeBackgroundBlur"]
        blur.adjust(toNormalizedSliderPosition: 0.3)
        XCTAssertEqual(automatic.value as? String, "0")
        let savedBlur = blur.value as? String
        let dimming = app.sliders["homeBackgroundDimming"]
        reveal(dimming, in: app)
        dimming.adjust(toNormalizedSliderPosition: 0.25)
        let visibility = app.sliders["homeBackgroundVisibility"]
        reveal(visibility, in: app)
        visibility.adjust(toNormalizedSliderPosition: 0.7)
        attach(app, "Home background controls")
        app.buttons["saveHomeBackground"].tap()
        app.terminate()
        app = home("background", reset: false)
        app.buttons["homeBackgroundButton"].tap()
        XCTAssertEqual(app.switches["automaticHomeBackground"].value as? String, "0")
        XCTAssertEqual(app.sliders["homeBackgroundBlur"].value as? String, savedBlur)
        let reset = app.buttons["resetHomeBackground"]
        for _ in 0..<3 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        XCTAssertEqual(app.switches["automaticHomeBackground"].value as? String, "1")
        app.buttons["saveHomeBackground"].tap()
    }

    /// Seed the simulator with a public test image using simctl addmedia before enabling this check.
    @MainActor
    func testSelectedPhotoPersistsAfterRelaunchAndCanBeRemoved() throws {
        guard ProcessInfo.processInfo.environment["JIBIJI_PHOTO_PICKER_UI"] == "1" else {
            throw XCTSkip("Seed a test photo and set TEST_RUNNER_JIBIJI_PHOTO_PICKER_UI=1 to exercise the system picker.")
        }
        var app = home("photo-background", reset: true)
        app.buttons["homeBackgroundButton"].tap()
        app.buttons["chooseHomePhoto"].tap()
        let picker = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow.photospicker")
        let photo = picker.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30), picker.debugDescription)
        photo.tap()
        XCTAssertTrue(app.buttons["removeHomePhoto"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["saveHomeBackground"].tap()
        app.terminate()
        app = home("photo-background", reset: false)
        attach(app, "Home with a custom photo")
        app.buttons["homeBackgroundButton"].tap()
        XCTAssertTrue(app.buttons["removeHomePhoto"].waitForExistence(timeout: 5))
        app.buttons["removeHomePhoto"].tap()
        app.buttons["saveHomeBackground"].tap()
        app.terminate()
        app = home("photo-background", reset: false)
        app.buttons["homeBackgroundButton"].tap()
        XCTAssertTrue(app.buttons["chooseHomePhoto"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["removeHomePhoto"].exists)
    }

    @MainActor private func home(_ name: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-\(name)"]
        if reset { app.launchArguments += ["-JIBIJIResetStore", "YES"] }
        app.launch()
        XCTAssertTrue(app.buttons["openNotebook"].waitForExistence(timeout: 10))
        app.buttons["openNotebook"].tap()
        XCTAssertTrue(app.buttons["homeBackgroundButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
