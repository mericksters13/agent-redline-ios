#if REDLINE
import XCTest

@MainActor
final class LayoutPrototypeTests: XCTestCase {
    private func launch(_ activation: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RedlineLayoutPrototype", "YES", "-RedlineLayoutActivation", activation]
        app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = activation == "external" ? "287" : "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["Fixed"].waitForExistence(timeout: 10))
        return app
    }

    private func inspect(_ label: String, in app: XCUIApplication, occurrence: Int = 0) -> String {
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        report.tap()
        app.staticTexts.matching(identifier: label).element(boundBy: occurrence).tap()
        let result = app.staticTexts["RedlineLayoutInspection"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let text = result.label
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Layout \(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        return text
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
                XCTAssertTrue(fixed.contains("_FrameLayout"), fixed)
                XCTAssertTrue(fixed.contains("width=180.0"), fixed)
                XCTAssertTrue(fixed.contains("height=44.0"), fixed)
                XCTAssertTrue(fixed.contains("edges=leading+trailing"), fixed)
                XCTAssertTrue(fixed.contains("leading: 16.0"), fixed)
                XCTAssertTrue(fixed.contains("alignment=leading"), fixed)
                XCTAssertTrue(fixed.contains("Runtime match by text and bounds"), fixed)
                for label in ["Nested", "Flexible", "Default padding", "Left", "Right", "Duplicate", "Overlap", "Synthetic selection"] {
                    let text = inspect(label, in: app)
                    print("LAYOUT_RESULT activation=\(activation) \(label): \(text)")
                    if label == "Nested" {
                        XCTAssertEqual(text.components(separatedBy: "leading: 5.0").count - 1, 2, text)
                        XCTAssertTrue(text.contains("width=120.0"), text)
                    }
                    if label == "Flexible" {
                        for expected in ["minWidth=100.0", "idealWidth=160.0", "maxWidth=inf", "minHeight=40.0", "alignment=trailing", "edges=top", "top: 7.0"] {
                            XCTAssertTrue(text.contains(expected), text)
                        }
                    }
                    if label == "Duplicate" {
                        XCTAssertTrue(text.contains("Runtime match by text and bounds"), text)
                        XCTAssertTrue(text.contains("leading: 4.0"), text)
                        let second = inspect(label, in: app, occurrence: 1)
                        XCTAssertTrue(second.contains("leading: 20.0"), second)
                        XCTAssertFalse(second.contains("leading: 4.0"), second)
                        print("LAYOUT_RESULT activation=\(activation) Duplicate second: \(second)")
                    }
                    if label == "Overlap" { XCTAssertTrue(text.contains("Ambiguous"), text) }
                    if label == "Default padding" { XCTAssertTrue(text.contains("system default"), text) }
                    if label == "Left" {
                        XCTAssertTrue(text.contains("spacing=12.0"), text)
                        XCTAssertTrue(text.contains("alignment=top"), text)
                        XCTAssertTrue(text.contains("LayoutPriorityLayout: priority=3.0"), text)
                    }
                    if label == "Right" { XCTAssertFalse(text.contains("priority=3.0"), text) }
                    if label == "Synthetic selection" { XCTAssertTrue(text.contains("No runtime text match"), text) }
                }
                // Repeat a previously selected sample to catch stale selection data.
                XCTAssertEqual(inspect("Fixed", in: app), fixed)
            }
            app.terminate()
        }
    }
}
#endif
