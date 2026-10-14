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

    /// Picks a sample and returns what its note card says was measured: the settings behind the
    /// size beside the role, or nothing when the card offers no layout.
    private func inspect(_ label: String, in app: XCUIApplication, occurrence: Int = 0) -> String {
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        let fixture = app.staticTexts.matching(identifier: label).element(boundBy: occurrence)
        let center = CGPoint(x: fixture.frame.midX, y: fixture.frame.midY)
        report.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: center.x, dy: center.y)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["RedlineNoteCard"].firstMatch.waitForExistence(timeout: 5))
        let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
        var text = result.waitForExistence(timeout: 2) ? result.label : ""
        XCTAssertFalse(text.contains("_PaddingLayout"), text)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        if text.isEmpty {
            // An element that could not be measured gets the plain card: no controls, no status.
            XCTAssertFalse(app.buttons["RedlineShowPadding"].exists)
            XCTAssertFalse(app.buttons["RedlineShowLayout"].exists)
        }
        attach("Layout \(label)", in: app)
        if label == "Left" {
            let parents = layoutRows(in: app).filter { $0.hasPrefix("Parent") }
            XCTAssertTrue(parents.contains { $0.contains("Spacing 12 pt") }, "\(parents)")
            text += "\n" + parents.joined(separator: "\n")
            attach("Parent layout Left", in: app)
        }
        app.buttons["Cancel"].tap()
        // The bar hides while a finger picks; it must be back once the pick is over.
        XCTAssertTrue(app.buttons["Close annotate mode"].isHittable)
        app.buttons["Close annotate mode"].tap()
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        return text
    }

    /// Opens the Layout panel and returns its rows, each as "Title: value".
    private func layoutRows(in app: XCUIApplication) -> [String] {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RedlineLayoutRow"))
        if !rows.firstMatch.exists {
            let button = app.buttons["RedlineShowLayout"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
        }
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        return (0..<rows.count).map { rows.element(boundBy: $0).label }
    }

    private func attach(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the Padding panel under the note, unless it is already open.
    private func openPadding(in app: XCUIApplication) {
        let preview = app.descendants(matching: .any)["RedlineComponentPreview"].firstMatch
        guard !preview.exists else { return }
        let button = app.buttons["RedlineShowPadding"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
    }

    func testLandscapeNonLayoutNotesStayCentered() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for drawing in [false, true] {
            let app = launch("early")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
            if drawing {
                app.buttons["Draw on the screen"].tap()
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
                    .press(
                        forDuration: 0.1,
                        thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
                    )
                app.buttons["Done drawing, add a note"].tap()
            } else {
                app.buttons["Capture this screen"].tap()
            }
            let card = app.otherElements["RedlineNoteCard"]
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            XCTAssertEqual(card.frame.midX, app.frame.midX, accuracy: 2)
            XCTAssertFalse(app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch.exists)
            attach(drawing ? "Centered landscape drawing note" : "Centered landscape screenshot note", in: app)
            app.terminate()
        }
    }

    func testUnsupportedSelectionFormOverlap() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-RedlineLayoutPrototype", "YES", "-RedlineLayoutActivation", "early",
            "-RedlineLayoutReviewFixture", "unsupported",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = "0"
        app.launch()
        let target = app.staticTexts["Unsupported panel"]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        let box = target.frame
        XCTAssertGreaterThan(box.height, app.frame.height * 0.8)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: box.midX, dy: box.midY)).tap()
        XCTAssertTrue(app.otherElements["RedlineNoteCard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch.exists)
        XCTAssertFalse(app.buttons["RedlineShowPadding"].exists)
        XCTAssertFalse(app.buttons["RedlineShowLayout"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["RedlineComponentPreview"].firstMatch.exists)
        XCTAssertTrue(app.otherElements["RedlineNoteCard"].frame.contains(CGPoint(x: box.midX, y: box.midY)))
        // The decorative thumbnail is accessibility-hidden; inspect it in this captured header.
        attach("Unavailable layout selection preview", in: app)
        app.terminate()
    }

    func testLocalizedTextLayoutInspection() {
        for (fixture, label, isButton) in [
            ("localized", "Exemple traduit", false),
            ("interpolated", "Compteur : 3", false),
            ("localizedButton", "Exemple traduit", true),
        ] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-RedlineLayoutPrototype", "YES", "-RedlineLayoutActivation", "early",
                "-RedlineLayoutReviewFixture", fixture, "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
            ]
            app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = "0"
            app.launch()
            let target = isButton ? app.buttons[label] : app.staticTexts[label]
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            let box = target.frame
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: box.midX, dy: box.midY)).tap()
            let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            XCTAssertTrue(result.label.contains("Padding: Horizontal · 8 pt"), result.label)
            openPadding(in: app)
            let left = app.buttons["RedlinePaddingLeft"]
            XCTAssertTrue(left.label.contains("8 pt"), left.label)
            left.tap()
            XCTAssertTrue(app.staticTexts["RedlineLayoutContext"].label.contains("Left padding: 8 pt"))
            attach("Localized " + fixture, in: app)
            app.terminate()
        }
    }

    func testSingleChildContainerPaddingOwnership() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-RedlineLayoutPrototype", "YES", "-RedlineLayoutActivation", "early",
            "-RedlineLayoutReviewFixture", "singleChild",
        ]
        app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = "0"
        app.launch()
        let result = inspect("Only child", in: app)
        XCTAssertTrue(result.contains("Padding: All sides · 3 pt"), result)
        XCTAssertFalse(result.contains("All sides · 12 pt"), result)
        XCTAssertFalse(result.contains("Frame: 180 × 60 pt"), result)
        app.terminate()
    }

    func testDrawingNoteAutofocusWithLayoutInspection() {
        let app = launch("early")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.buttons["Draw on the screen"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        app.buttons["Done drawing, add a note"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["RedlineNoteText"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch.exists)
        attach("Drawing note retains autofocus", in: app)
        app.terminate()
    }

    func testScreenshotNoteAutofocusWithLayoutInspection() {
        let app = launch("early")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.buttons["Capture this screen"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["RedlineNoteText"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch.exists)
        attach("Screenshot note retains autofocus", in: app)
        app.terminate()
    }

    func testPlainButtonLayoutInspection() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-RedlineLayoutPrototype", "YES", "-RedlineLayoutActivation", "early",
            "-RedlineLayoutButtonDemo", "YES",
        ]
        app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = "0"
        app.launch()
        let button = app.buttons["Continue"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let target = button.frame
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.midX, dy: target.midY)).tap()
        let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("160"), result.label)
        openPadding(in: app)
        let left = app.buttons["RedlinePaddingLeft"]
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        XCTAssertTrue(left.label.contains("8 pt"), left.label)
        left.tap()
        XCTAssertTrue(app.staticTexts["RedlineLayoutContext"].label.contains("Left padding: 8 pt"))
        attach("Plain button padding and frame", in: app)
        app.buttons["Cancel"].tap()
        app.terminate()
    }

    func testLayoutTabOnNormalLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["SWIFTUI_VIEW_DEBUG"] = "0"
        app.launch()
        let tabs = app.tabBars
        XCTAssertTrue(tabs.buttons["Recipes"].waitForExistence(timeout: 10))
        tabs.buttons["Layout"].tap()
        XCTAssertTrue(app.staticTexts["Fixed"].waitForExistence(timeout: 5))
        attach("Layout samples in the demo tab", in: app)
        let result = inspect("Fixed", in: app)
        XCTAssertTrue(result.contains("Frame: 180 × 44 pt"), result)
        XCTAssertTrue(result.contains("Padding: Horizontal · 16 pt"), result)
        tabs.buttons["Recipes"].tap()
        XCTAssertTrue(app.navigationBars["Recipes"].exists)
        let recipe = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "list.row.", ".summary")
        ).firstMatch
        _ = inspect(recipe.label, in: app)
        app.terminate()
    }

    func testRecipesLayoutInspection() {
        let app = XCUIApplication()
        app.launch()
        let title = app.buttons["list.row.black-bean-tacos.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        for (name, element) in [
            ("Recipe summary", app.staticTexts["list.row.black-bean-tacos.summary"]),
            ("Recipe title", title),
            ("Recipe icon", app.images["list.row.black-bean-tacos.icon"]),
            ("Recipe row", app.otherElements["list.row.black-bean-tacos"]),
        ] {
            let center =
                name == "Recipe row"
                ? CGVector(dx: element.frame.minX + element.frame.width * 0.75, dy: element.frame.maxY - 8)
                : CGVector(dx: element.frame.midX, dy: element.frame.midY)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
            app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()
            let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5))
            if name == "Recipe row" {
                XCTAssertTrue(result.label.contains("Padding: Vertical · 4 pt"), result.label)
                openPadding(in: app)
                let top = app.buttons["RedlinePaddingTop"]
                XCTAssertTrue(top.isHittable)
                top.tap()
                XCTAssertTrue(app.staticTexts["RedlineLayoutContext"].label.contains("Top padding: 4 pt (measured)"))
            } else {
                // Without measured padding there is nothing to tap, so the Padding control is absent.
                XCTAssertFalse(app.buttons["RedlineShowPadding"].exists)
                if name == "Recipe summary" {
                    XCTAssertTrue(result.label.contains("Frame: Width 150 pt"), result.label)
                    // The frame that cuts the summary off can be sent, once its row is chosen.
                    let rows = layoutRows(in: app)
                    XCTAssertEqual(rows.first, "Frame: Width 150 pt · Natural height · Leading")
                    app.buttons["RedlineLayoutRow0"].tap()
                    let context = app.staticTexts["RedlineLayoutContext"]
                    XCTAssertTrue(context.label.contains("Frame: Width 150 pt"), context.label)
                } else if name == "Recipe icon" {
                    XCTAssertTrue(result.label.contains("Frame: 40 × 40 pt"), result.label)
                }
            }
            attach(name, in: app)
            app.buttons["Cancel"].tap()
            app.buttons["Close annotate mode"].tap()
        }
        title.tap()
        let start = app.buttons["detail.start"]
        for _ in 0..<3 where !start.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(start.isHittable)
        let center = CGVector(dx: start.frame.midX, dy: start.frame.midY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()
        let result = app.descendants(matching: .any)["RedlineLayoutInspection"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Padding: Leading 44 pt"), result.label)
        openPadding(in: app)
        let left = app.buttons["RedlinePaddingLeft"]
        XCTAssertTrue(left.isHittable)
        left.tap()
        XCTAssertTrue(app.staticTexts["RedlineLayoutContext"].label.contains("Left padding: 44 pt (measured)"))
        attach("Cooking button", in: app)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        // A fresh capture after scrolling must use the changed content offset.
        let scroll = app.scrollViews.firstMatch
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(
                forDuration: 0.1,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                withVelocity: .slow,
                thenHoldForDuration: 0.3
            )
        let scrolledCenter = CGVector(dx: start.frame.midX, dy: start.frame.midY)
        XCTAssertTrue(start.isHittable)
        XCTAssertGreaterThan(start.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(scrolledCenter).tap()
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("Padding: Leading 44 pt"), result.label)
        openPadding(in: app)
        XCTAssertTrue(left.isHittable)
        attach("Cooking button after scrolling", in: app)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testMeasuredOverlayStates() {
        let app = launch("early")
        for (label, expected) in [
            ("Fixed", "Frame: 180 × 44 pt"), ("Nested", "Leading 5 pt"),
            ("Flexible", "Measured frame"), ("Default padding", "Padding: System default"),
            ("Left", "Layout priority: 3"),
        ] {
            XCTAssertTrue(inspect(label, in: app).contains(expected))
        }
        // Ambiguous and synthetic selections get the plain card.
        for label in ["Overlap", "Synthetic selection"] {
            XCTAssertEqual(inspect(label, in: app), "")
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
                XCTAssertEqual(fixed, "")
            } else {
                XCTAssertTrue(fixed.contains("Frame: 180 × 44 pt"), fixed)
                XCTAssertTrue(fixed.contains("Padding: Horizontal · 16 pt"), fixed)
                XCTAssertTrue(fixed.contains("Alignment: Leading"), fixed)
                XCTAssertFalse(fixed.contains("_FrameLayout"), fixed)
                XCTAssertFalse(fixed.contains("SwiftUI"), fixed)
                for label in [
                    "Nested", "Flexible", "Default padding", "Left", "Right", "Duplicate", "Overlap",
                    "Synthetic selection",
                ] {
                    let text = inspect(label, in: app)
                    print("LAYOUT_RESULT activation=\(activation) \(label): \(text)")
                    if label == "Nested" {
                        XCTAssertEqual(text.components(separatedBy: "Leading 5 pt").count - 1, 2, text)
                        XCTAssertTrue(text.contains("Frame: 120 × 36 pt"), text)
                    }
                    if label == "Flexible" {
                        for expected in [
                            "Min 100 pt", "Ideal 160 pt", "Fill available space", "Min 40 pt", "Alignment: Trailing",
                            "Top 7 pt", "Measured frame",
                        ] {
                            XCTAssertTrue(text.contains(expected), text)
                        }
                    }
                    if label == "Duplicate" {
                        XCTAssertTrue(text.contains("All sides · 4 pt"), text)
                        let second = inspect(label, in: app, occurrence: 1)
                        XCTAssertTrue(second.contains("All sides · 20 pt"), second)
                        XCTAssertFalse(second.contains("All sides · 4 pt"), second)
                        print("LAYOUT_RESULT activation=\(activation) Duplicate second: \(second)")
                    }
                    if label == "Overlap" { XCTAssertEqual(text, "") }
                    if label == "Default padding" {
                        XCTAssertTrue(text.contains("Padding: System default"), text)
                        XCTAssertTrue(text.contains("Measured padding: All sides · 16 pt"), text)
                    }
                    if label == "Left" {
                        XCTAssertTrue(text.contains("Parent: Horizontal stack · Spacing 12 pt · Top"), text)
                        XCTAssertTrue(text.contains("Layout priority: 3"), text)
                    }
                    if label == "Right" { XCTAssertFalse(text.contains("Layout priority: 3"), text) }
                    if label == "Synthetic selection" { XCTAssertEqual(text, "") }
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
        openPadding(in: app)
        app.buttons["RedlinePaddingLeft"].tap()
        XCTAssertTrue(app.staticTexts["RedlineLayoutContext"].label.contains("Left padding: 16 pt (measured)"))
        // Allow the native pressed appearance to settle before capturing.
        Thread.sleep(forTimeInterval: 0.35)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Visual inspector ready"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testElementNoteOpensWithTheKeyboardAndOnePanelAtATime() {
        let app = launch("early")
        let fixture = app.staticTexts["Fixed"]
        let center = CGVector(dx: fixture.frame.midX, dy: fixture.frame.midY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()
        let note = app.descendants(matching: .any)["RedlineNoteText"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let preview = app.descendants(matching: .any)["RedlineComponentPreview"].firstMatch
        XCTAssertFalse(preview.exists)
        attach("Element note opens with the keyboard", in: app)

        // A panel takes the keyboard's place, under the note.
        openPadding(in: app)
        XCTAssertGreaterThan(preview.frame.minY, note.frame.maxY)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        attach("Padding panel under the note", in: app)

        // Another panel replaces it.
        XCTAssertFalse(layoutRows(in: app).isEmpty)
        XCTAssertFalse(preview.exists)
        attach("Layout panel under the note", in: app)

        // Going back to the note closes the panel.
        note.tap()
        XCTAssertFalse(app.buttons["RedlineLayoutRow0"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testPanelsKeepTheSelectionAndTheDraft() {
        let app = launch("early")
        let fixture = app.staticTexts["Fixed"]
        let center = CGVector(dx: fixture.frame.midX, dy: fixture.frame.midY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()
        let padding = app.buttons["RedlineShowPadding"]
        XCTAssertTrue(padding.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["RedlineComponentPreview"].firstMatch.exists)
        XCTAssertFalse(app.buttons["RedlinePaddingLeft"].exists)
        XCTAssertEqual(padding.value as? String ?? "", "")
        XCTAssertTrue(app.buttons["Add note"].isHittable)

        let note = app.descendants(matching: .any)["RedlineNoteText"].firstMatch
        note.typeText("Keep this draft")
        openPadding(in: app)
        let left = app.buttons["RedlinePaddingLeft"]
        XCTAssertTrue(left.waitForExistence(timeout: 5), app.debugDescription)
        left.tap()
        let context = app.staticTexts["RedlineLayoutContext"]
        XCTAssertTrue(context.label.contains("Left padding: 16 pt (measured)"), context.label)
        attach("Left padding included", in: app)

        // Closed, the control still says what is included.
        padding.tap()
        XCTAssertFalse(left.exists)
        XCTAssertEqual(padding.value as? String, "left padding included")
        XCTAssertEqual(note.value as? String, "Keep this draft")
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        attach("Padding closed with its mark", in: app)

        // The hierarchy opens under the same name, note and buttons.
        let hierarchy = app.buttons["RedlineShowHierarchy"]
        XCTAssertTrue(hierarchy.isHittable)
        hierarchy.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RedlineHierarchyRow"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertFalse(app.staticTexts["Hierarchy"].exists)
        let card = app.descendants(matching: .any)["RedlineNoteCard"].firstMatch
        XCTAssertTrue(card.staticTexts.matching(identifier: "Fixed").firstMatch.exists)
        XCTAssertEqual(note.value as? String, "Keep this draft")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        attach("Hierarchy under the note", in: app)
        hierarchy.tap()
        XCTAssertFalse(rows.firstMatch.exists)
        XCTAssertEqual(padding.value as? String, "left padding included")

        // A layout row joins what is included.
        XCTAssertEqual(layoutRows(in: app).first, "Frame: 180 × 44 pt · Leading")
        let frame = app.buttons["RedlineLayoutRow0"]
        frame.tap()
        XCTAssertEqual(frame.value as? String, "Included in note")
        XCTAssertTrue(context.label.contains("Left padding: 16 pt (measured)"), context.label)
        XCTAssertTrue(context.label.contains("Frame: 180 × 44 pt · Leading"), context.label)
        attach("Frame included", in: app)

        openPadding(in: app)
        XCTAssertEqual(left.value as? String, "Included in note")
        XCTAssertEqual(app.buttons["RedlineShowLayout"].value as? String, "frame included")
        XCTAssertEqual(note.value as? String, "Keep this draft")
        // The card is still resizing from one panel to the other; let the footer come to rest.
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()

        // The next note starts with nothing included and no panel open.
        let nextFixture = app.staticTexts["Default padding"]
        let nextCenter = CGVector(dx: nextFixture.frame.midX, dy: nextFixture.frame.midY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(nextCenter).tap()
        XCTAssertTrue(padding.waitForExistence(timeout: 5))
        XCTAssertEqual(padding.value as? String ?? "", "")
        XCTAssertFalse(app.buttons["RedlinePaddingTop"].exists)
        openPadding(in: app)
        XCTAssertEqual(app.buttons["RedlinePaddingTop"].value as? String, "Not included")
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testFormAvoidsSelectedComponent() {
        for label in ["Fixed", "Flexible", "Default padding", "Duplicate"] {
            let app = launch("early")
            let target = app.staticTexts.matching(identifier: label).firstMatch
            let targetFrame = target.frame
            let point = CGVector(dx: targetFrame.midX, dy: targetFrame.midY)
            let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue"))
                .firstMatch
            XCTAssertTrue(report.waitForExistence(timeout: 10))
            report.tap()
            app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
            let card = app.descendants(matching: .any)["RedlineNoteCard"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            func check(_ state: String) {
                Thread.sleep(forTimeInterval: 0.4)
                let frame = card.frame
                XCTAssertTrue(
                    frame.maxY <= targetFrame.minY - 7 || frame.minY >= targetFrame.maxY + 7,
                    "\(label) \(state): card \(frame) overlaps target \(targetFrame)"
                )
                XCTAssertTrue(app.buttons["Add note"].isHittable)
                attach("\(label) form \(state)", in: app)
            }
            check("collapsed")
            let collapsedHeight = card.frame.height
            let title = card.staticTexts.matching(identifier: label).firstMatch
            let note = app.descendants(matching: .any)["RedlineNoteText"].firstMatch
            XCTAssertLessThanOrEqual(title.frame.minY - card.frame.minY, 32, "Extra space above the component name")
            XCTAssertLessThanOrEqual(
                app.buttons["Add note"].frame.minY - note.frame.maxY,
                28,
                "Extra space between the note and footer"
            )
            openPadding(in: app)
            check("expanded")
            app.buttons["RedlineShowPadding"].tap()
            check("collapsed again")
            XCTAssertEqual(card.frame.height, collapsedHeight, accuracy: 1)
            app.buttons["Cancel"].tap()
            app.terminate()
        }
    }

    func testFormPlacementWhileTyping() {
        let app = launch("early")
        let target = app.staticTexts["Flexible"]
        let targetFrame = target.frame
        let report = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 10))
        report.tap()
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: targetFrame.midX, dy: targetFrame.midY)).tap()
        let note = app.descendants(matching: .any)["RedlineNoteText"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("Keep the component visible while I write.\nA second line.\nA third line.")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let card = app.descendants(matching: .any)["RedlineNoteCard"].firstMatch
        let frame = card.frame
        XCTAssertTrue(
            frame.maxY <= targetFrame.minY - 7 || frame.minY >= targetFrame.maxY + 7,
            "Typing: card \(frame) overlaps target \(targetFrame)"
        )
        // Automation may expose an offscreen keyboard when text entry uses a hardware keyboard.
        let visibleBottom = min(app.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleBottom - 7)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        XCTAssertTrue((note.value as? String)?.contains("A third line.") == true)
        attach("Form stays clear with growing draft", in: app)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testHierarchyDragSelection() {
        let app = XCUIApplication()
        app.launch()
        let row = app.otherElements["list.row.black-bean-tacos"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let point = CGVector(dx: row.frame.minX + row.frame.width * 0.75, dy: row.frame.maxY - 8)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
        XCTAssertTrue(app.buttons["RedlineShowHierarchy"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["RedlineComponentPreview"].firstMatch.exists)
        attach("Recipe row snapshot starts collapsed", in: app)
        app.buttons["RedlineShowHierarchy"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RedlineHierarchyRow"))
        XCTAssertGreaterThan(rows.count, 3)
        let first = rows.element(boundBy: 0)
        let last = rows.element(boundBy: rows.count - 1)
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(last.isHittable)
        let x = app.frame.midX
        func coordinate(_ element: XCUIElement) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: element.frame.midY))
        }
        attach("Hierarchy before dragging", in: app)
        coordinate(first).press(
            forDuration: 0.35,
            thenDragTo: coordinate(last),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
        XCTAssertEqual(last.value as? String, "Selected")
        XCTAssertNotEqual(first.value as? String, "Selected")
        attach("Hierarchy after downward traversal", in: app)
        coordinate(last).press(
            forDuration: 0.35,
            thenDragTo: coordinate(first),
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertNotEqual(last.value as? String, "Selected")
        attach("Hierarchy after reverse traversal", in: app)
        let branch = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RedlineHierarchyBranch"))
            .firstMatch
        let count = rows.count
        branch.tap()
        XCTAssertEqual(rows.count, 1)
        branch.tap()
        XCTAssertEqual(rows.count, count)
        last.tap()
        XCTAssertEqual(last.value as? String, "Selected")
        first.tap()
        XCTAssertEqual(first.value as? String, "Selected")
        // An ordinary swipe is a scroll, never a traversal: the selection stays.
        app.scrollViews["RedlineHierarchy"].swipeUp(velocity: .fast)
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertNotEqual(last.value as? String, "Selected")
        attach("Hierarchy ordinary swipe keeps the selection", in: app)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        app.buttons["RedlineShowHierarchy"].tap()
        XCTAssertFalse(rows.firstMatch.exists)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testHierarchyWidensWithoutLeavingTheNote() {
        let app = XCUIApplication()
        app.launch()
        let summary = app.staticTexts["list.row.black-bean-tacos.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        let point = CGVector(dx: summary.frame.midX, dy: summary.frame.midY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(point).tap()
        let hierarchy = app.buttons["RedlineShowHierarchy"]
        XCTAssertTrue(hierarchy.waitForExistence(timeout: 5))
        hierarchy.tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RedlineHierarchyRow"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        // The summary's owner holds the title and the summary.
        let local = rows.count
        XCTAssertEqual(local, 3)
        attach("Hierarchy of the titles", in: app)
        let up = app.buttons["RedlineHierarchyUp"]
        XCTAssertTrue(up.isHittable)
        XCTAssertTrue(up.label.contains("list.row.black-bean-tacos"), up.label)
        up.tap()
        // One element out: the row, with its icon and time beside the titles.
        XCTAssertGreaterThan(rows.count, local)
        // The name in the header is still the summary's, shortened as the card shortens names.
        let card = app.descendants(matching: .any)["RedlineNoteCard"].firstMatch
        func names(_ start: String) -> XCUIElement {
            card.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", start)).firstMatch
        }
        XCTAssertTrue(names(String(summary.label.prefix(12))).exists)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        XCTAssertTrue(app.buttons["Add note"].isHittable)
        attach("Hierarchy widened to the row", in: app)
        // Choosing the row names it in the header, with the tree still open.
        let row = rows.element(boundBy: 0)
        row.tap()
        XCTAssertEqual(row.value as? String, "Selected")
        XCTAssertTrue(names("list.row.black-bean").waitForExistence(timeout: 5))
        attach("Row chosen from the widened hierarchy", in: app)
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testRepeatedFlexiblePreviewToggles() {
        let app = launch("early")
        let fixture = app.staticTexts["Flexible"]
        let center = CGVector(dx: fixture.frame.midX, dy: fixture.frame.midY)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.coordinate(withNormalizedOffset: .zero).withOffset(center).tap()
        openPadding(in: app)
        let top = app.buttons["RedlinePaddingTop"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        top.tap()
        let context = app.staticTexts["RedlineLayoutContext"]
        XCTAssertTrue(context.label.contains("Top padding: 7 pt (measured)"), context.label)
        let padding = app.buttons["RedlineShowPadding"]
        attach("Flexible padding open", in: app)
        for cycle in 1...3 {
            padding.tap()
            XCTAssertFalse(top.exists)
            XCTAssertTrue(app.buttons["RedlineShowLayout"].isHittable)
            XCTAssertTrue(app.buttons["Add note"].isHittable)
            XCTAssertEqual(padding.value as? String, "top padding included")
            attach("Flexible padding closing \(cycle)", in: app)
            Thread.sleep(forTimeInterval: 0.5)
            attach("Flexible padding closed \(cycle)", in: app)
            padding.tap()
            XCTAssertTrue(top.waitForExistence(timeout: 5))
            XCTAssertEqual(top.value as? String, "Included in note")
            attach("Flexible padding opening \(cycle)", in: app)
        }
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

    func testPaddingSelectionAndSavedContext() {
        let app = launch("early")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.staticTexts["Default padding"].tap()
        openPadding(in: app)
        let top = app.buttons["RedlinePaddingTop"]
        let bottom = app.buttons["RedlinePaddingBottom"]
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        top.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        let verticalContext = app.staticTexts["RedlineLayoutContext"]
        XCTAssertTrue(
            verticalContext.label.contains("Top padding: 16 pt (measured; system default)"),
            verticalContext.label
        )
        XCTAssertTrue(
            verticalContext.label.contains("Bottom padding: 16 pt (measured; system default)"),
            verticalContext.label
        )
        app.buttons["Cancel"].tap()
        app.buttons["Close annotate mode"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Report a UI issue")).firstMatch.tap()
        app.staticTexts["Fixed"].tap()
        openPadding(in: app)
        let left = app.buttons["RedlinePaddingLeft"]
        let right = app.buttons["RedlinePaddingRight"]
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        // Tap near the control's edge, away from its value.
        left.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.65)).tap()
        right.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.65)).tap()
        right.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.65)).tap()
        let context = app.staticTexts["RedlineLayoutContext"]
        XCTAssertTrue(context.label.contains("Left padding: 16 pt (measured)"), context.label)
        XCTAssertFalse(context.label.contains("Right padding"), context.label)
        attach("Selected left padding", in: app)
        app.buttons["Add note"].tap()
        // The saved note is empty, since nothing was typed; the list names what it includes.
        let notes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show ")).firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        XCTAssertTrue(app.staticTexts["No note"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "with left padding")).firstMatch.exists
        )
        attach("Saved note names what it includes", in: app)
        // The Mac-side verification reads the saved draft after this real tap.
        app.buttons["Hide notes"].tap()
        app.buttons["Close annotate mode"].tap()
        app.terminate()
    }

}
#endif
