import XCTest

/// Simulator checks for the first page. Touch drags stand in for Apple Pencil here;
/// Pencil input, pressure, and palm rejection are checked by hand on a physical iPad.
final class NotePageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        // On an iPad paired with Apple Pencil, finger drags don't draw ("Only Draw with Apple Pencil"),
        // so these would fail for reasons unrelated to the app.
        throw XCTSkip("UI tests draw with finger drags and run on the Simulator only.")
        #endif
    }

    @MainActor
    func testInkIsSavedAndReopenedAfterRelaunch() throws {
        let app = launch(notebook: "relaunch", reset: true)
        let status = app.staticTexts["pageStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Empty page")

        draw(in: app, from: CGVector(dx: 0.30, dy: 0.35), to: CGVector(dx: 0.60, dy: 0.35))
        draw(in: app, from: CGVector(dx: 0.45, dy: 0.25), to: CGVector(dx: 0.45, dy: 0.50))
        waitForLabel("2 strokes · Saved", on: status)
        assertInk(in: app, visibleAt: inkPoints, blankAt: blankPoints)
        attachScreenshot(of: app, named: "Before relaunch")

        app.terminate()
        let relaunched = launch(notebook: "relaunch", reset: false)
        let reopenedStatus = relaunched.staticTexts["pageStatus"]
        XCTAssertTrue(reopenedStatus.waitForExistence(timeout: 10))
        XCTAssertEqual(reopenedStatus.label, "2 strokes · Saved")
        // The strokes must be drawn on screen, not just loaded.
        assertInk(in: relaunched, visibleAt: inkPoints, blankAt: blankPoints)
        // Opening a page isn't an undoable step, so Undo can't blank the reopened page.
        XCTAssertFalse(relaunched.buttons["Undo"].firstMatch.isEnabled)
        XCTAssertEqual(reopenedStatus.label, "2 strokes · Saved")
        attachScreenshot(of: relaunched, named: "After relaunch")
    }

    /// Midpoints of the two strokes drawn above (away from where they cross), and an empty spot.
    private let inkPoints = [CGVector(dx: 0.37, dy: 0.35), CGVector(dx: 0.45, dy: 0.44)]
    private let blankPoints = [CGVector(dx: 0.80, dy: 0.60)]

    @MainActor
    func testUndoAndRedoAreSaved() throws {
        let app = launch(notebook: "undo", reset: true)
        let status = app.staticTexts["pageStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        draw(in: app, from: CGVector(dx: 0.30, dy: 0.40), to: CGVector(dx: 0.60, dy: 0.40))
        draw(in: app, from: CGVector(dx: 0.30, dy: 0.50), to: CGVector(dx: 0.60, dy: 0.50))
        waitForLabel("2 strokes · Saved", on: status)

        // Undo and redo are the buttons in the system tool palette.
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForEnabled(), app.debugDescription)
        undo.tap()
        waitForLabel("1 stroke · Saved", on: status)

        let redo = app.buttons["Redo"].firstMatch
        XCTAssertTrue(redo.waitForEnabled())
        redo.tap()
        waitForLabel("2 strokes · Saved", on: status)

        undo.tap()
        waitForLabel("1 stroke · Saved", on: status)
        app.terminate()

        let relaunched = launch(notebook: "undo", reset: false)
        let reopenedStatus = relaunched.staticTexts["pageStatus"]
        XCTAssertTrue(reopenedStatus.waitForExistence(timeout: 10))
        waitForLabel("1 stroke · Saved", on: reopenedStatus)
    }

    @MainActor
    func testRecognitionCheckOpensAndCloses() throws {
        let app = launch(notebook: "recognition", reset: true)
        XCTAssertTrue(app.staticTexts["pageStatus"].waitForExistence(timeout: 10))
        draw(in: app, from: CGVector(dx: 0.30, dy: 0.40), to: CGVector(dx: 0.60, dy: 0.40))

        let paletteUndo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(paletteUndo.waitForExistence(timeout: 5))

        app.buttons["Check recognition"].tap()
        let available = app.descendants(matching: .any)["recognizerAvailable"]
        let unavailable = app.descendants(matching: .any)["recognizerUnavailable"]
        let deadline = Date.now.addingTimeInterval(30)
        while !available.exists, !unavailable.exists, Date.now < deadline {
            _ = available.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(available.exists || unavailable.exists, "The recognition check never finished")
        // The tool palette hides under the sheet, so it can't change ink the student can't see.
        XCTAssertFalse(paletteUndo.exists && paletteUndo.isHittable, "The tool palette is still usable above the sheet")
        attachScreenshot(of: app, named: "Recognition check")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["pageStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["pageStatus"].label, "1 stroke · Saved")
        // And it comes back when the sheet closes.
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: paletteUndo)
        XCTAssertEqual(XCTWaiter().wait(for: [returned], timeout: 5), .completed, "The tool palette didn't come back")
    }

    // MARK: - Helpers

    /// Launches with a disposable notebook. Test notebooks start with the pen whatever tool
    /// PencilKit remembered (the tests never tap palette tools: in the Simulator, drags made
    /// right after a palette tool switch don't render).
    @MainActor
    private func launch(notebook: String, reset: Bool, file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JIBIJIStoreName", "uitest-\(notebook)"]
        if reset {
            app.launchArguments += ["-JIBIJIResetStore", "YES"]
        }
        app.launch()
        let pen = app.buttons["Pen"].firstMatch
        XCTAssertTrue(pen.waitForExistence(timeout: 10), "The tool palette isn't showing", file: file, line: line)
        XCTAssertTrue(pen.isSelected, "A test notebook should start with the pen", file: file, line: line)
        return app
    }

    @MainActor
    private func draw(in app: XCUIApplication, from start: CGVector, to end: CGVector) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: start).press(
            forDuration: 0.05,
            thenDragTo: window.coordinate(withNormalizedOffset: end),
            withVelocity: .slow,
            thenHoldForDuration: 0.05
        )
    }

    @MainActor
    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 10,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected “\(label)”, found “\(element.label)”", file: file, line: line)
    }

    /// Checks the rendered window for ink near each point in `visibleAt` and none near `blankAt`.
    /// Ink is any pixel that contrasts with the page background (sampled at the first blank point),
    /// so this works in light and dark appearance. Polls briefly because PencilKit renders a
    /// reopened drawing asynchronously.
    @MainActor
    private func assertInk(in app: XCUIApplication, visibleAt inkPoints: [CGVector], blankAt blankPoints: [CGVector],
                           timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date.now.addingTimeInterval(timeout)
        var missing = inkPoints
        repeat {
            guard let pixels = WindowPixels(app.windows.firstMatch.screenshot().image), let backgroundPoint = blankPoints.first else {
                return XCTFail("Couldn't read the screenshot", file: file, line: line)
            }
            let background = pixels.brightness(at: backgroundPoint)
            missing = inkPoints.filter { !pixels.hasInk(near: $0, background: background) }
            if missing.isEmpty {
                for point in blankPoints {
                    XCTAssertFalse(pixels.hasInk(near: point, background: background), "Unexpected ink at \(point)", file: file, line: line)
                }
                return
            }
            _ = app.staticTexts["pageStatus"].waitForExistence(timeout: 0.25)
        } while Date.now < deadline
        XCTFail("No ink on screen at \(missing)", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// RGBA pixels of a screenshot, top row first.
private struct WindowPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Sum of the red, green, and blue values (0–765) at a normalized point.
    func brightness(at point: CGVector) -> Int {
        brightness(x: Int(point.dx * CGFloat(width)), y: Int(point.dy * CGFloat(height)))
    }

    /// True if a pixel within `radius` pixels of the normalized point contrasts strongly with `background`.
    func hasInk(near point: CGVector, background: Int, radius: Int = 10) -> Bool {
        let centerX = Int(point.dx * CGFloat(width))
        let centerY = Int(point.dy * CGFloat(height))
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius)
            where abs(brightness(x: x, y: y) - background) > 400 {
                return true
            }
        }
        return false
    }

    private func brightness(x: Int, y: Int) -> Int {
        let i = (y * width + x) * 4
        return Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
    }
}

private extension XCUIElement {
    @MainActor
    func waitForEnabled(timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
