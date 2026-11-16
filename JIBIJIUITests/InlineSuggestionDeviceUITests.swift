import XCTest

/// Opt-in M2 check of inline suggestions, meant for the physical iPad. It never writes: it opens a
/// notebook that was seeded beforehand with a synthetic 35-stroke page, and only taps suggestion controls.
///
/// Seed `uitest-m2-replay` so its `page-1.drawing` is the synthetic page (copied with `devicectl`), then run with
///
///     TEST_RUNNER_JIBIJI_M2_DEVICE_UI=1 xcodebuild test … -only-testing:JIBIJIUITests/InlineSuggestionDeviceUITests
///
/// The notebook is never reset; the tests leave it with no accepted notes and its ink untouched.
final class InlineSuggestionDeviceUITests: XCTestCase {
    private let notebook = "uitest-m2-replay"
    private let strokeStatus = "35 strokes · Saved"
    private let expectedGloss = "to be responsible for"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["JIBIJI_M2_DEVICE_UI"] == "1" else {
            throw XCTSkip("Opt-in: pass TEST_RUNNER_JIBIJI_M2_DEVICE_UI=1 to xcodebuild.")
        }
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("On-device handwriting recognition needs iPadOS 27.")
        }
    }

    @MainActor
    func testSuggestionDismissAlternateEditAcceptAndUndoKeepInk() throws {
        let app = launch()
        let status = app.staticTexts["pageStatus"]
        waitForLabel(strokeStatus, on: status)

        // Request: a provisional chip with the expected gloss, below the ink and inside the page.
        requestSuggestion(in: app)
        var chip = app.buttons["acceptSuggestion"]
        XCTAssertTrue(chip.label.contains(expectedGloss), "Chip says “\(chip.label)”")
        assertChipIsBelowToolbarAndOnScreen(chip, in: app)
        attachScreenshot(of: app, named: "Pending suggestion")

        // Dismiss removes it without touching the ink; a new request brings it back.
        tapMenuItem("Dismiss", in: app)
        XCTAssertTrue(chip.waitForDisappearance(), "Dismiss left the chip")
        waitForLabel(strokeStatus, on: status)
        requestSuggestion(in: app)
        chip = app.buttons["acceptSuggestion"]
        XCTAssertTrue(chip.label.contains(expectedGloss))

        // Alternative: only offered when the vocabulary has one for this word.
        app.buttons["suggestionOptions"].tap()
        let alternate = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "chéngdān")).firstMatch
        XCTAssertTrue(alternate.waitForExistence(timeout: 5), "No alternative listed.\n\(app.debugDescription)")
        alternate.tap()
        let alternateChip = app.buttons.matching(identifier: "acceptSuggestion").matching(NSPredicate(format: "label CONTAINS %@", "承担")).firstMatch
        XCTAssertTrue(alternateChip.waitForExistence(timeout: 5), "Choosing the alternative didn't change the chip")
        attachScreenshot(of: app, named: "Alternative selected")

        // Cancelling an edit changes nothing; editing then adding accepts the user's wording.
        tapMenuItem("Edit…", in: app)
        let alert = app.alerts["Edit note"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alternateChip.waitForExistence(timeout: 5), "Cancel dropped the pending chip")
        XCTAssertFalse(notes(in: app).firstMatch.exists, "Cancel accepted a note")

        tapMenuItem("Edit…", in: app)
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(" (edited)")
        alert.buttons["Add"].tap()
        let accepted = notes(in: app).firstMatch
        XCTAssertTrue(accepted.waitForExistence(timeout: 5), "The edited note wasn't added")
        XCTAssertTrue(accepted.label.contains("(edited)"), "Note says “\(accepted.label)”")
        XCTAssertFalse(chip.exists, "A pending chip remained after accepting")
        attachScreenshot(of: app, named: "Accepted note")

        // Undo removes the note, and the ink is exactly as seeded.
        app.buttons["undoSuggestion"].tap()
        XCTAssertTrue(accepted.waitForDisappearance(), "Undo left the note")
        waitForLabel(strokeStatus, on: status)
    }

    @MainActor
    func testAcceptedNotePersistsAcrossRelaunch() throws {
        var app = launch()
        waitForLabel(strokeStatus, on: app.staticTexts["pageStatus"])
        requestSuggestion(in: app)
        app.buttons["acceptSuggestion"].tap()
        XCTAssertTrue(notes(in: app).firstMatch.waitForExistence(timeout: 5))

        app.terminate()
        app = launch(clearNotes: false)
        waitForLabel(strokeStatus, on: app.staticTexts["pageStatus"])
        let reopened = notes(in: app)
        XCTAssertTrue(reopened.firstMatch.waitForExistence(timeout: 10), "The accepted note didn't come back")
        XCTAssertEqual(reopened.count, 1)
        XCTAssertTrue(reopened.firstMatch.label.contains(expectedGloss), "Note says “\(reopened.firstMatch.label)”")
        attachScreenshot(of: app, named: "Reopened with note")
        removeAcceptedNotes(in: app) // leave the notebook as seeded
    }

    // MARK: - Helpers

    /// Launches the isolated, pre-seeded notebook without resetting it. By default it clears notes left by an
    /// earlier run; pass `clearNotes: false` to reopen with the notes as they were saved.
    @MainActor
    private func launch(clearNotes: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", notebook]
        app.launch()
        XCTAssertTrue(app.staticTexts["pageStatus"].waitForExistence(timeout: 15), "The notebook didn't open")
        if clearNotes { removeAcceptedNotes(in: app) }
        return app
    }

    @MainActor
    private func notes(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "acceptedAnnotation")
    }

    @MainActor
    private func removeAcceptedNotes(in app: XCUIApplication) {
        for _ in 0..<5 {
            let note = notes(in: app).firstMatch
            guard note.waitForExistence(timeout: 2) else { return }
            note.press(forDuration: 1)
            let remove = app.buttons["Remove note"]
            guard remove.waitForExistence(timeout: 3) else { return XCTFail("No Remove note menu") }
            remove.tap()
            _ = note.waitForDisappearance(timeout: 3)
        }
    }

    /// Taps Suggest and waits for the (on-device, so possibly slow) recognition to produce a chip.
    @MainActor
    private func requestSuggestion(in app: XCUIApplication) {
        app.buttons["suggestButton"].tap()
        let chip = app.buttons["acceptSuggestion"]
        XCTAssertTrue(chip.waitForExistence(timeout: 60), "No suggestion appeared. Status: \(app.staticTexts["suggestionStatus"].label)")
    }

    @MainActor
    private func tapMenuItem(_ title: String, in app: XCUIApplication) {
        app.buttons["suggestionOptions"].tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No “\(title)” in the options menu.\n\(app.debugDescription)")
        item.tap()
    }

    /// The chip belongs under some ink: not under the navigation bar and fully inside the window.
    /// (The screenshot attached next to this check shows it against the ink.)
    @MainActor
    private func assertChipIsBelowToolbarAndOnScreen(_ chip: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch.frame
        XCTAssertTrue(chip.isHittable, "The chip can't be tapped")
        XCTAssertGreaterThanOrEqual(chip.frame.minY, bar.maxY, "The chip sits under the toolbar")
        XCTAssertTrue(window.contains(chip.frame), "The chip \(chip.frame) is outside the window \(window)")
    }

    @MainActor
    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, found “\(element.label)”", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    @MainActor
    func waitForDisappearance(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
