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
        case idle, picking, noting, tray
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
    private(set) var editingID: UUID?
    private(set) var toast: String?
    private(set) var screenSize = CGSize.zero
    private(set) var safeAreaInsets = UIEdgeInsets.zero
    private(set) var keyboardTop = CGFloat.infinity
    /// Center of the floating button, in screen points. Nil until the window has a size.
    private(set) var buttonCenter: CGPoint?

    var safeAreaTop: CGFloat { safeAreaInsets.top }

    var selected: ElementSnapshot? {
        levels.indices.contains(levelIndex) ? levels[levelIndex] : nil
    }

    var canStepUp: Bool { levelIndex + 1 < levels.count }
    var canStepDown: Bool { levelIndex > 0 }

    /// The chip in the note box: the selected element, or the one being edited.
    var noteTitle: String {
        if let editingID, let annotation = annotations.first(where: { $0.id == editingID }) {
            return annotation.element.displayName
        }
        return selected?.displayName ?? ""
    }

    @ObservationIgnored private var window: OverlayWindow?
    @ObservationIgnored private var elements: [ElementSnapshot] = []
    @ObservationIgnored private var screen = ScreenInfo()
    @ObservationIgnored private var screenshot: UIImage?
    @ObservationIgnored private var appKeyWindow: UIWindow?
    @ObservationIgnored private var trayReturnMode = Mode.idle
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
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
        window.rootViewController = host
        window.onLayout = { [weak self] window in
            self?.updateLayout(size: window.bounds.size, insets: window.safeAreaInsets)
        }
        window.isHidden = false
        self.window = window

        annotations = store.loadDraft()
        observeKeyboard()

        if UserDefaults.standard.bool(forKey: "AgenticDebuggingPickOnLaunch") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                enterPicking()
            }
        }
    }

    // MARK: - Pick mode

    func enterPicking() {
        guard mode == .idle, let window else { return }
        let appWindows = self.appWindows()
        elements = AccessibilityTree.elements(in: appWindows, screenBounds: window.bounds)
        screen = AccessibilityTree.screen(of: appWindows.first(where: \.isKeyWindow) ?? appWindows.last, elements: elements)
        screenshot = AccessibilityTree.screenshot(of: appWindows, bounds: window.bounds)
        levels = []
        refreshMarkers()
        setMode(.picking)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        let found = ElementSelection.levels(at: point, in: elements, screenSize: screenSize)
        if found.first != levels.first, found.first != nil {
            selectionFeedback.selectionChanged()
        }
        levels = found
        levelIndex = 0
    }

    func finishHover(at point: CGPoint) {
        hover(at: point)
        guard selected != nil else { return }
        noteText = ""
        editingID = nil
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
        if let editingID, let index = annotations.firstIndex(where: { $0.id == editingID }) {
            annotations[index].note = note
            persist()
            endNoting(returningTo: .tray)
            return
        }
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
        let returnMode: Mode = editingID == nil ? .picking : .tray
        levels = []
        endNoting(returningTo: returnMode)
    }

    func edit(_ annotation: Annotation) {
        guard mode == .tray else { return }
        editingID = annotation.id
        noteText = annotation.note
        levels = []
        beginNoting()
    }

    func delete(_ annotation: Annotation) {
        annotations.removeAll { $0.id == annotation.id }
        store.deleteScreenshot(named: annotation.screenshot)
        persist()
        refreshMarkers()
        if annotations.isEmpty, mode == .tray { setMode(trayReturnMode) }
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
        case .noting:
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

    /// The top of the note box: under the element if it fits above the keyboard,
    /// otherwise above it, otherwise as low as it can go.
    func noteBoxTop(height: CGFloat) -> CGFloat {
        let top = safeAreaTop + 8
        let bottom = min(keyboardTop, screenSize.height) - 8
        guard editingID == nil, let frame = selected?.frame else { return top }
        if frame.maxY + 8 + height <= bottom { return frame.maxY + 8 }
        if frame.minY - 8 - height >= top { return frame.minY - 8 - height }
        return max(top, bottom - height)
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

    private func setMode(_ newMode: Mode) {
        mode = newMode
        window?.claimsAllTouches = newMode != .idle
    }

    private func beginNoting() {
        appKeyWindow = appWindows().first(where: \.isKeyWindow)
        setMode(.noting)
        window?.makeKey()
    }

    private func endNoting(returningTo next: Mode) {
        noteText = ""
        editingID = nil
        setMode(next)
        appKeyWindow?.makeKey()
        appKeyWindow = nil
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
            MainActor.assumeIsolated { self?.updateKeyboard(frame) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeyboard(nil) }
        })
    }

    private func updateKeyboard(_ frame: CGRect?) {
        guard let frame, frame.minY < screenSize.height else {
            keyboardTop = .infinity
            return
        }
        keyboardTop = frame.minY
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
