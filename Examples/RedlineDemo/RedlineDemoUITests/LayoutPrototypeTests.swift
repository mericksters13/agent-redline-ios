#if REDLINE
import XCTest

@MainActor
final class LayoutPrototypeTests: XCTestCase {
    private func launch(_ activation: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RedlineLayoutPrototype", "YES", "-RedlineLayoutActivation", activation]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = activation == "external" ? "287" : "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixed"].waitForExistence(timeout: 10))
        return app
    }

    private func inspect(_ label: String, in app: XCUIApplication, occurrence: Int = 0) -> String {
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        let fixture = app.staticTexts.matching(identifier: label).element(boundBy: occurrence)
        let center = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)
        report.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: center.x, dy: center.y)).tap()
        let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        var text = result.label
        XCTAssertFalse(text.contains("_PaddingLayout"), text)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        attach("Layout \(label)", in: app)
        if label == "Left" {
            app.buttons["Layout details"].tap()
            let scroll = app.scrollViews["RedlineNoteScroll"]
            scroll.swipeUp()
            let parent = app.buttons["Parent layout"]
            XCTAssertTrue(parent.exists)
            parent.tap()
            let values = app.descendants(matching: .any)["RedlineParentLayout"].firstMatch
            XCTAssertTrue(values.waitForExistence(timeout: 5))
            text += "\n" + values.label
            XCTAssertTrue(values.label.contains("Spacing: 12 pt"), values.label)
            scroll.swipeUp()
            attach("Parent layout Left", in: app)
        }
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        return text
    }

    private func attach(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMeasuredOverlayStates() {
        let app = launch("early")
        for (label, expected) in [("Fixed", "Frame: 180 × 44 pt"), ("Nested", "Leading 5 pt"),
                                  ("Flexible", "Measured frame"), ("Default padding", "Padding: System default"),
                                  ("Left", "Layout priority: 3"), ("Overlap", "Multiple views"),
                                  ("Synthetic selection", "No matching rendered view")] {
            XCTAssertTrue(inspect(label, in: app).contains(expected))
        }
        app.terminate()
    }

    func testActivationAndTapResults() {
        for activation in ["none", "late", "early", "external"] {
            let app = launch(activation)
            if activation == "late" { sleep(2) }
            let fixed = inspect("Fixed", in: app)
            print("LAYOUT_RESULT activation=\(activation) Fixed: \(fixed)")
            if ["none", "late"].contains(activation) {
                XCTAssertTrue(fixed.contains("unavailable"), fixed)
            } else {
                XCTAssertTrue(fixed.contains("Frame: 180 × 44 pt"), fixed)
                XCTAssertTrue(fixed.contains("Padding: Horizontal · 16 pt"), fixed)
                XCTAssertTrue(fixed.contains("Alignment: Leading"), fixed)
                XCTAssertTrue(fixed.contains("Matched by text and bounds"), fixed)
                XCTAssertFalse(fixed.contains("_FrameLayout"), fixed)
                XCTAssertFalse(fixed.contains("SwiftUI"), fixed)
                for label in ["Nested", "Flexible", "Default padding", "Left", "Right", "Duplicate", "Overlap", "Synthetic selection"] {
                    let text = inspect(label, in: app)
                    print("LAYOUT_RESULT activation=\(activation) \(label): \(text)")
                    if label == "Nested" {
                        XCTAssertEqual(text.components(separatedBy: "Leading 5 pt").count - 1, 2, text)
                        XCTAssertTrue(text.contains("Frame: 120 × 36 pt"), text)
                    }
                    if label == "Flexible" {
                        for expected in ["Min 100 pt", "Ideal 160 pt", "Fill available space", "Min 40 pt", "Alignment: Trailing", "Top 7 pt", "Measured frame"] {
                            XCTAssertTrue(text.contains(expected), text)
                        }
                    }
                    if label == "Duplicate" {
                        XCTAssertTrue(text.contains("Matched by text and bounds"), text)
                        XCTAssertTrue(text.contains("All sides · 4 pt"), text)
                        let second = inspect(label, in: app, occurrence: 1)
                        XCTAssertTrue(second.contains("All sides · 20 pt"), second)
                        XCTAssertFalse(second.contains("All sides · 4 pt"), second)
                        print("LAYOUT_RESULT activation=\(activation) Duplicate second: \(second)")
                    }
                    if label == "Overlap" { XCTAssertTrue(text.contains("Multiple views"), text) }
                    if label == "Default padding" {
                        XCTAssertTrue(text.contains("Padding: System default"), text)
                        XCTAssertTrue(text.contains("Measured padding: All sides · 16 pt"), text)
                    }
                    if label == "Left" {
                        XCTAssertTrue(text.contains("Spacing: 12 pt"), text)
                        XCTAssertTrue(text.contains("Alignment: Top"), text)
                        XCTAssertTrue(text.contains("Layout priority: 3"), text)
                    }
                    if label == "Right" { XCTAssertFalse(text.contains("Layout priority: 3"), text) }
                    if label == "Synthetic selection" { XCTAssertTrue(text.contains("No matching rendered view"), text) }
                }
                // Repeat a previously selected sample to catch stale selection data.
                XCTAssertEqual(inspect("Fixed", in: app), fixed)
            }
            app.terminate()
        }
    }

    func testLargeTextAndLandscapeInspector() {
        let large = launch("early", largeText: true)
        XCTAssertTrue(inspect("Fixed", in: large).contains("Frame: 180 × 44 pt"))
        large.terminate()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = launch("early")
        // The tall fixture column puts Fixed above the landscape viewport; Nested is visible.
        XCTAssertTrue(inspect("Nested", in: landscape).contains("Frame: 120 × 36 pt"))
        landscape.terminate()
    }

    func testShowVisualInspector() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch("early")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.staticTexts["Fixed"].tap()
        let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Frame: 180 × 44 pt"), result.label)
        app.buttons["RedlinePaddingLeft"].tap()
        XCTAssertTrue(app.staticTexts["RedlineLayoutContext"].label.contains("Left padding: 16 pt (measured)"))
        // Allow the native pressed appearance to settle before capturing.
        Thread.sleep(forTimeInterval: 0.35)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Visual inspector ready"
        attachment.lifetime = .keepAlways
        add(attachment)
    }


    func testPaddingSelectionAndSavedContext() {
        let app = launch("early")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.staticTexts["Default padding"].tap()
        let top = app.buttons["RedlinePaddingTop"]
        let bottom = app.buttons["RedlinePaddingBottom"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        top.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        let verticalContext = app.staticTexts["RedlineLayoutContext"]
        XCTAssertTrue(verticalContext.label.contains("Top padding: 16 pt (measured; system default)"), verticalContext.label)
        XCTAssertTrue(verticalContext.label.contains("Bottom padding: 16 pt (measured; system default)"), verticalContext.label)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.staticTexts["Fixed"].tap()
        let left = app.buttons["RedlinePaddingLeft"]
        let right = app.buttons["RedlinePaddingRight"]
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        // Tap the line near its end tick, away from the numeric label.
        left.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.65)).tap()
        right.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.65)).tap()
        right.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.65)).tap()
        let context = app.staticTexts["RedlineLayoutContext"]
        XCTAssertTrue(context.label.contains("Left padding: 16 pt (measured)"), context.label)
        XCTAssertFalse(context.label.contains("Right padding"), context.label)
        attach("Selected left padding", in: app)
        app.buttons["Add note"].tap()
        // The Mac-side verification reads the saved draft after this real tap.
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

}
#endif
