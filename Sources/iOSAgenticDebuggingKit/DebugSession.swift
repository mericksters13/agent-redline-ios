#if AGENTIC_DEBUGGING && canImport(UIKit)
import os
import SwiftUI
import UIKit

/// Owns the debugger for the life of the app: the overlay window, the floating
/// button, pick mode and the draft of annotations.
@MainActor
@Observable
final class DebugSession {
    static let shared = DebugSession()

    enum Mode {
        case idle, picking, noting, tray, viewer
    }

    struct Marker: Identifiable {
        var id: UUID
        var number: Int
        var frame: CGRect
    }

    private(set) var mode = Mode.idle
    private(set) var annotations: [Annotation] = []
    /// What's under the finger, innermost first. `levelIndex` picks one of them.
    private(set) var levels: [ElementSnapshot] = []
    private(set) var levelIndex = 0
    /// Numbered markers for annotations already made on the current screen.
    private(set) var markers: [Marker] = []
    var noteText = ""
    /// The note showing in the full-screen viewer.
    private(set) var viewerID: UUID?
    private(set) var toast: String?
    private(set) var screenSize = CGSize.zero
    private(set) var safeAreaInsets = UIEdgeInsets.zero
    private(set) var keyboardTop = CGFloat.infinity
    /// True from the moment the note card asks for the keyboard until the keyboard
    /// reports its frame, so the card can open where it will end up.
    private(set) var awaitingKeyboard = false
    /// Center of the floating button, in screen points. Nil until the window has a size.
    private(set) var buttonCenter: CGPoint?
    /// The screen being picked on.
    private(set) var screen = ScreenInfo()

    var safeAreaTop: CGFloat { safeAreaInsets.top }

    var selected: ElementSnapshot? {
        levels.indices.contains(levelIndex) ? levels[levelIndex] : nil
    }

    var canStepUp: Bool { levelIndex + 1 < levels.count }
    var canStepDown: Bool { levelIndex > 0 }

    var screenTitle: String { screen.title ?? "This screen" }

    /// The number the note being written will get.
    var nextNumber: Int { annotations.count + 1 }

    @ObservationIgnored private var window: OverlayWindow?
    @ObservationIgnored private var elements: [ElementSnapshot] = []
    @ObservationIgnored private var screenshot: UIImage?
    @ObservationIgnored private var appKeyWindow: UIWindow?
    @ObservationIgnored private var trayReturnMode = Mode.idle
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    /// Full-size screenshots for the viewer, kept for the few notes around the one showing.
    @ObservationIgnored private var fullScreenshots: [UUID: UIImage] = [:]
    /// True while a finger is down in pick mode.
    @ObservationIgnored private var touchIsDown = false
    @ObservationIgnored private let store = ReportStore.standard
    @ObservationIgnored private let selectionFeedback = UISelectionFeedbackGenerator()
    @ObservationIgnored private let logger = Logger(subsystem: "iOSAgenticDebuggingKit", category: "session")

    private init() {}

    // MARK: - Install

    func install(in scene: UIWindowScene) {
        guard window == nil else { return }
        AccessibilityTree.enableAutomation()

        let window = OverlayWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: OverlayView(session: self))
        host.view.backgroundColor = .clear
        // The overlay places everything itself from the window's insets and the keyboard frame.
        // Left on, the keyboard shrinks the space SwiftUI lays out in and re-centers full-screen views.
        host.safeAreaRegions = []
        // Dark at the UIKit level too, so the keyboard and system popovers always match the black panels.
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.onLayout = { [weak self] window in
            self?.updateLayout(size: window.bounds.size, insets: window.safeAreaInsets)
        }
        window.isHidden = false
        self.window = window

        annotations = store.loadDraft()
        observeKeyboard()

        // Launch arguments for checking layouts on a device without touching it:
        // -AgenticDebuggingPickOnLaunch YES opens pick mode, -AgenticDebuggingPickPoint "0.5,0.8"
        // then picks the element at that fraction of the screen, and
        // -AgenticDebuggingNoteText "..." fills in the note. -AgenticDebuggingOpenViewer YES
        // opens the viewer on the first saved note.
        let defaults = UserDefaults.standard
        // -AgenticDebuggingLaunchDelay waits that many seconds first, for apps that load slowly.
        let launchDelay = max(defaults.double(forKey: "AgenticDebuggingLaunchDelay"), 1)
        if defaults.bool(forKey: "AgenticDebuggingOpenViewer") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                enterPicking()
                try? await Task.sleep(for: .milliseconds(300))
                toggleTray()
                if let first = annotations.first { openViewer(first) }
            }
        }
        if defaults.bool(forKey: "AgenticDebuggingPickOnLaunch") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                enterPicking()
                try? await Task.sleep(for: .milliseconds(300))
                let point: (String) -> CGPoint? = { key in
                    let parts = defaults.string(forKey: key)?.split(separator: ",").compactMap { Double($0) }
                    guard let parts, parts.count == 2 else { return nil }
                    return CGPoint(x: parts[0] * self.screenSize.width, y: parts[1] * self.screenSize.height)
                }
                // -AgenticDebuggingHoverPoint holds a finger-down hover there instead of picking.
                if let hover = point("AgenticDebuggingHoverPoint") {
                    self.hover(at: hover)
                    return
                }
                guard let pick = point("AgenticDebuggingPickPoint") else { return }
                finishHover(at: pick)
                if let text = defaults.string(forKey: "AgenticDebuggingNoteText") { noteText = text }
            }
        }
    }

    // MARK: - Pick mode

    func enterPicking() {
        guard mode == .idle, window != nil else { return }
        // A list still gliding from a scroll would keep moving after the screen is
        // read, leaving every outline behind. Stop it, let it settle, then read.
        AccessibilityTree.stopScrolling(in: appWindows())
        levels = []
        setMode(.picking)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            if mode == .picking { readScreen() }
        }
    }

    func exitPicking() {
        guard mode == .picking || mode == .tray else { return }
        levels = []
        markers = []
        elements = []
        screenshot = nil
        setMode(.idle)
    }

    func hover(at point: CGPoint) {
        guard mode == .picking else { return }
        if !touchIsDown {
            // Each new touch reads the screen again, so positions, saved-note markers
            // and the report screenshot match what is on screen right now.
            touchIsDown = true
            readScreen()
        }
        let found = ElementSelection.levels(at: point, in: elements, screenSize: screenSize)
        if found.first != levels.first, found.first != nil {
            selectionFeedback.selectionChanged()
        }
        levels = found
        levelIndex = 0
    }

    func finishHover(at point: CGPoint) {
        hover(at: point)
        touchIsDown = false
        guard selected != nil else { return }
        noteText = ""
        beginNoting()
    }

    func stepUp() {
        if canStepUp { levelIndex += 1 }
    }

    func stepDown() {
        if canStepDown { levelIndex -= 1 }
    }

    // MARK: - Notes

    func saveNote() {
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let element = selected, let screenshot else { return }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        do {
            let image = AccessibilityTree.outlining(element.frame, in: screenshot)
            try store.saveScreenshot(image.pngData() ?? Data(), named: fileName)
        } catch {
            logger.error("Couldn't save the screenshot: \(error.localizedDescription, privacy: .public)")
        }
        annotations.append(Annotation(
            id: id,
            createdAt: .now,
            note: note,
            element: element,
            ancestors: Array(levels.dropFirst(levelIndex + 1)),
            screen: screen,
            screenshot: fileName
        ))
        persist()
        levels = []
        refreshMarkers()
        endNoting(returningTo: .picking)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func cancelNote() {
        levels = []
        endNoting(returningTo: .picking)
    }

    func delete(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations.remove(at: index)
        thumbnails[annotation.id] = nil
        fullScreenshots[annotation.id] = nil
        store.deleteScreenshot(named: annotation.screenshot)
        persist()
        refreshMarkers()
        if mode == .viewer {
            // Show the next note, or the one before when the last was deleted.
            if annotations.isEmpty {
                closeViewer()
            } else {
                viewerID = annotations[min(index, annotations.count - 1)].id
            }
        } else if annotations.isEmpty, mode == .tray {
            setMode(trayReturnMode)
        }
    }

    // MARK: - Viewer

    /// Opens the full-screen viewer on a note from the notes list.
    func openViewer(_ annotation: Annotation) {
        guard mode == .tray else { return }
        viewerID = annotation.id
        setMode(.viewer)
    }

    func showInViewer(_ id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        viewerID = id
    }

    func closeViewer() {
        viewerID = nil
        fullScreenshots = [:]
        setMode(annotations.isEmpty ? trayReturnMode : .tray)
    }

    func updateNote(_ id: UUID, to text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].note != note else { return }
        annotations[index].note = note
        persist()
    }

    /// The note's whole screenshot, with its element outlined.
    func fullScreenshot(for annotation: Annotation) -> UIImage? {
        if let cached = fullScreenshots[annotation.id] { return cached }
        let url = store.draftDirectory.appending(path: annotation.screenshot)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        // Keep only a few; a long session can collect many full-screen images.
        if fullScreenshots.count >= 5 { fullScreenshots.removeAll() }
        fullScreenshots[annotation.id] = image
        return image
    }

    // MARK: - Tray and send

    func toggleTray() {
        switch mode {
        case .tray:
            setMode(trayReturnMode)
        case .picking, .idle:
            guard !annotations.isEmpty else { return }
            trayReturnMode = mode
            setMode(.tray)
        case .noting, .viewer:
            break
        }
    }

    func send() {
        guard !annotations.isEmpty else { return }
        do {
            let folder = try store.send(annotations, app: .current, device: .current, date: .now)
            logger.notice("Report saved at \(folder.path, privacy: .public)")
            let count = annotations.count
            annotations = []
            thumbnails = [:]
            levels = []
            markers = []
            elements = []
            screenshot = nil
            setMode(.idle)
            show(toast: count == 1 ? "Saved 1 note on this iPhone" : "Saved \(count) notes on this iPhone")
        } catch {
            logger.error("Couldn't save the report: \(error.localizedDescription, privacy: .public)")
            show(toast: "Couldn't save the report")
        }
    }

    /// A close crop of the picked element from the current screenshot, for the note card
    /// when the element itself is hidden behind the keyboard or the card.
    func selectedElementPreview() -> UIImage? {
        guard let frame = selected?.frame, let image = screenshot else { return nil }
        return Self.crop(image, around: frame, screenWidth: screenSize.width)
    }

    /// A square crop for a thumbnail. A wide element keeps its leading end and a tall one its
    /// top, where the icon and title usually are; the middle of a row is often empty.
    private static func crop(_ image: UIImage, around frame: CGRect, screenWidth: CGFloat) -> UIImage? {
        guard let cgImage = image.cgImage, screenWidth > 0 else { return nil }
        let scale = CGFloat(cgImage.width) / screenWidth
        var area = frame.insetBy(dx: -12, dy: -12)
        let side = min(area.width, area.height)
        area.size = CGSize(width: side, height: side)
        let crop = CGRect(x: area.minX * scale, y: area.minY * scale, width: area.width * scale, height: area.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !crop.isEmpty, let cropped = cgImage.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped)
    }

    /// A close crop of the annotation's screenshot around its element, for the notes list.
    func thumbnail(for annotation: Annotation) -> UIImage? {
        if let cached = thumbnails[annotation.id] { return cached }
        let url = store.draftDirectory.appending(path: annotation.screenshot)
        guard let image = UIImage(contentsOfFile: url.path),
              let thumbnail = Self.crop(image, around: annotation.element.frame, screenWidth: screenSize.width)
        else { return nil }
        thumbnails[annotation.id] = thumbnail
        return thumbnail
    }

    /// The keyboard's top edge for placing the note card. Until the keyboard reports its
    /// frame, the last keyboard height stands in for it, so the card opens where it will
    /// end up instead of jumping when the keyboard arrives.
    var noteKeyboardTop: CGFloat {
        awaitingKeyboard ? screenSize.height - expectedKeyboardHeight : keyboardTop
    }

    /// The note card's top edge.
    func noteCardTop(height: CGFloat, reservedHeight: CGFloat) -> CGFloat {
        let keyboard = noteKeyboardTop
        return NoteCardPlacement.top(
            element: selected?.frame,
            height: height,
            reservedHeight: reservedHeight,
            top: safeAreaTop,
            bottom: min(keyboard, screenSize.height - safeAreaInsets.bottom)
        )
    }

    private static let keyboardHeightKey = "AgenticDebuggingKeyboardHeight"

    /// The last keyboard height seen, or a typical iPhone keyboard with the
    /// suggestion bar before any keyboard has shown.
    private var expectedKeyboardHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.keyboardHeightKey)
        return saved > 0 ? saved : screenSize.height * 0.385
    }

    // MARK: - Floating button

    /// Follows the finger during a drag, kept on screen. No snapping yet.
    func dragButton(to point: CGPoint) {
        buttonCenter = CGPoint(
            x: min(max(point.x, 0), screenSize.width),
            y: min(max(point.y, 0), screenSize.height)
        )
    }

    /// Called when a drag ends: the button snaps to an edge and remembers where it rests.
    func moveButton(to proposed: CGPoint) {
        let area = buttonArea
        let center = FloatingButtonPlacement.snapped(proposed, within: area)
        buttonCenter = center
        let fraction = FloatingButtonPlacement.fraction(of: center, within: area)
        UserDefaults.standard.set([fraction.x, fraction.y], forKey: Self.buttonPositionKey)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Only the button takes touches while the debugger is idle; the rest go to the app.
    func setButtonFrame(_ frame: CGRect?) {
        window?.touchableRect = frame
    }

    private static let buttonPositionKey = "AgenticDebuggingButtonPosition"

    private var buttonArea: CGRect {
        FloatingButtonPlacement.restingArea(
            screen: screenSize,
            top: safeAreaInsets.top,
            left: safeAreaInsets.left,
            bottom: safeAreaInsets.bottom,
            right: safeAreaInsets.right
        )
    }

    private func updateLayout(size: CGSize, insets: UIEdgeInsets) {
        guard size != screenSize || insets != safeAreaInsets || buttonCenter == nil else { return }
        let previousArea = buttonArea
        let previousCenter = buttonCenter
        screenSize = size
        safeAreaInsets = insets
        guard size.width > 0, size.height > 0 else { return }
        if let previousCenter, previousArea.width > 0 {
            let fraction = FloatingButtonPlacement.fraction(of: previousCenter, within: previousArea)
            buttonCenter = FloatingButtonPlacement.center(fromFraction: fraction, within: buttonArea)
        } else if let saved = UserDefaults.standard.array(forKey: Self.buttonPositionKey) as? [Double], saved.count == 2 {
            buttonCenter = FloatingButtonPlacement.center(fromFraction: CGPoint(x: saved[0], y: saved[1]), within: buttonArea)
        } else {
            buttonCenter = FloatingButtonPlacement.defaultCenter(within: buttonArea)
        }
    }

    // MARK: - Private

    /// Keyboard focus moves to the debugger when it leaves idle and back to the app when
    /// it returns to idle, never in between: the first tap after each handoff gets lost,
    /// so handing focus back and forth around every note cost a tap each time.
    private func setMode(_ newMode: Mode) {
        let wasIdle = mode == .idle
        mode = newMode
        window?.claimsAllTouches = newMode != .idle
        if wasIdle, newMode != .idle {
            appKeyWindow = appWindows().first(where: \.isKeyWindow)
            window?.makeKey()
        } else if !wasIdle, newMode == .idle {
            appKeyWindow?.makeKey()
            appKeyWindow = nil
        }
    }

    private func beginNoting() {
        awaitingKeyboard = keyboardTop == .infinity
        setMode(.noting)
        // A hardware keyboard never shows the on-screen one; stop waiting for it.
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            if awaitingKeyboard {
                withAnimation(.smooth(duration: 0.25)) { awaitingKeyboard = false }
            }
        }
    }

    private func endNoting(returningTo next: Mode) {
        noteText = ""
        awaitingKeyboard = false
        setMode(next)
    }

    /// Reads every element's position, the screen's name and a screenshot, all at the same moment.
    private func readScreen() {
        guard let window else { return }
        let appWindows = self.appWindows()
        elements = AccessibilityTree.elements(in: appWindows, screenBounds: window.bounds)
        screen = AccessibilityTree.screen(of: appWindows.first(where: \.isKeyWindow) ?? appWindows.last, elements: elements)
        screenshot = AccessibilityTree.screenshot(of: appWindows, bounds: window.bounds)
        refreshMarkers()
    }

    private func persist() {
        do {
            try store.saveDraft(annotations)
        } catch {
            logger.error("Couldn't save the draft: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshMarkers() {
        markers = annotations.enumerated().compactMap { index, annotation in
            guard annotation.screen == screen,
                  let match = ElementSelection.match(annotation.element, in: elements)
            else { return nil }
            return Marker(id: annotation.id, number: index + 1, frame: match.frame)
        }
    }

    private func show(toast message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }

    /// The app's own visible windows, bottom to top, without the debugger's.
    private func appWindows() -> [UIWindow] {
        guard let scene = window?.windowScene else { return [] }
        return scene.windows
            .filter { !($0 is OverlayWindow) && !$0.isHidden && !String(describing: type(of: $0)).contains("TextEffects") }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    private func observeKeyboard() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated { self?.updateKeyboard(frame, duration: duration) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated { self?.updateKeyboard(nil, duration: duration) }
        })
    }

    /// Moves the note card with the keyboard, on the keyboard's own timing curve.
    private func updateKeyboard(_ frame: CGRect?, duration: Double) {
        let visible = frame.map { $0.minY < screenSize.height && $0.height > 0 } ?? false
        withAnimation(.timingCurve(0.38, 0.7, 0.125, 1, duration: max(duration, 0.2))) {
            if visible, let frame {
                keyboardTop = frame.minY
                awaitingKeyboard = false
                UserDefaults.standard.set(Double(screenSize.height - frame.minY), forKey: Self.keyboardHeightKey)
            } else {
                keyboardTop = .infinity
            }
        }
    }
}

extension Report.App {
    static var current: Report.App {
        let info = Bundle.main.infoDictionary ?? [:]
        return Report.App(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String
        )
    }
}

extension Report.Device {
    @MainActor static var current: Report.Device {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return Report.Device(model: model, systemName: UIDevice.current.systemName, systemVersion: UIDevice.current.systemVersion)
    }
}
#endif
