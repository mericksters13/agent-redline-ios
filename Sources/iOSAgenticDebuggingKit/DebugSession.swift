#if AGENTIC_DEBUGGING && canImport(UIKit)
import os
import SwiftUI
import UIKit

/// Owns the debugger for the life of the app: the overlay window, the floating
/// button, pick mode, attachments, suggested screenshots and the draft.
@MainActor
@Observable
final class DebugSession {
    static let shared = DebugSession()

    enum Mode {
        case idle, picking, noting, tray, viewer, attaching
    }

    /// Images waiting for their note: what the note card is about when no element is picked.
    struct PendingAttachment {
        var kind: Annotation.Kind
        /// The images, or small previews of them while the full ones load.
        var images: [UIImage]
        var screen: ScreenInfo?
        /// True for a suggested screenshot: its note box sends the report.
        var sendsReport: Bool
        /// How many images, known before they finish loading.
        var count = 1
        /// The full-size images, while they load. The note box opens without waiting for them.
        var loading: Task<[UIImage], Never>?
    }

    /// A screenshot offered at the side of the screen.
    struct Suggestion: Identifiable {
        let id = UUID()
        var image: UIImage
        var kind: Annotation.Kind
        var screen: ScreenInfo?
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
    /// The attachment the note card is for, when it isn't for a picked element.
    private(set) var pending: PendingAttachment?
    /// A screenshot just taken, offered at the side until it is sent or dismissed.
    private(set) var suggestion: Suggestion?
    /// The attachment button's frame, where the attachment surface grows from.
    var attachAnchor = CGRect.zero

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
    /// Where Cancel or Add on the note card goes back to.
    @ObservationIgnored private var notingReturnMode = Mode.picking
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    /// Full-size images for the viewer, kept for the few around the one showing.
    @ObservationIgnored private var fullImages: [String: UIImage] = [:]
    /// True while Add note waits for photos that are still loading.
    @ObservationIgnored private var isSavingNote = false
    /// Images still being written to the draft. Send waits for them.
    @ObservationIgnored private var writes: [Task<Void, Never>] = []
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
        observeScreenshots()
        // On a cold launch the app became active before the debugger was installed.
        Task {
            try? await Task.sleep(for: .seconds(1))
            offerRecentScreenshot()
        }

        // Launch arguments for checking layouts on a device without touching it:
        // -AgenticDebuggingPickOnLaunch YES opens pick mode, -AgenticDebuggingPickPoint "0.5,0.8"
        // then picks the element at that fraction of the screen, and
        // -AgenticDebuggingNoteText "..." fills in the note. -AgenticDebuggingOpenViewer YES
        // opens the viewer on the first saved note. -AgenticDebuggingOpenAttachments YES opens
        // the attachment surface, and -AgenticDebuggingSimulateScreenshot YES acts as if a
        // screenshot was taken, which a simulator can't do from the command line.
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
        if defaults.bool(forKey: "AgenticDebuggingOpenAttachments") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                enterPicking()
                try? await Task.sleep(for: .milliseconds(400))
                openAttachments()
            }
        }
        if defaults.bool(forKey: "AgenticDebuggingSimulateScreenshot") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: UIApplication.shared)
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
        pending = nil
        notingReturnMode = .picking
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
        if let pending {
            guard !isSavingNote else { return }
            guard let loading = pending.loading else {
                saveAttachment(pending, note: note)
                return
            }
            // Photos still loading: save once they're in. The note box stays until then.
            isSavingNote = true
            Task {
                var ready = pending
                ready.images = await loading.value
                ready.loading = nil
                isSavingNote = false
                guard self.pending != nil, !ready.images.isEmpty else { return }
                saveAttachment(ready, note: note)
            }
            return
        }
        guard let element = selected, let screenshot else { return }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let image = AccessibilityTree.outlining(element.frame, in: screenshot)
        thumbnails[id] = Self.crop(image, around: element.frame, screenWidth: screenSize.width)
        writeImages([image], named: [fileName], asPNG: true)
        annotations.append(Annotation(
            id: id,
            createdAt: .now,
            note: note,
            kind: .element,
            element: element,
            ancestors: Array(levels.dropFirst(levelIndex + 1)),
            screen: screen,
            screenshots: [fileName]
        ))
        persist()
        levels = []
        refreshMarkers()
        endNoting(returningTo: notingReturnMode)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func cancelNote() {
        levels = []
        pending?.loading?.cancel()
        pending = nil
        endNoting(returningTo: notingReturnMode)
    }

    /// Saves the attachment's images and adds it to the draft. A suggested screenshot
    /// then sends the report, with everything already in the draft.
    private func saveAttachment(_ attachment: PendingAttachment, note: String) {
        let id = UUID()
        // The app's own screens keep every pixel sharp; photos are stored smaller.
        let isScreen = attachment.kind == .screen
        let files = attachment.images.indices.map { "\(id.uuidString)-\($0 + 1).\(isScreen ? "png" : "jpg")" }
        thumbnails[id] = attachment.images.first.flatMap(Self.topSquare(of:))
        writeImages(attachment.images, named: files, asPNG: isScreen)
        annotations.append(Annotation(
            id: id,
            createdAt: .now,
            note: note,
            kind: attachment.kind,
            element: nil,
            ancestors: [],
            screen: attachment.screen,
            screenshots: files
        ))
        persist()
        pending = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if attachment.sendsReport {
            noteText = ""
            awaitingKeyboard = false
            send()
        } else {
            endNoting(returningTo: notingReturnMode)
        }
    }

    func delete(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations.remove(at: index)
        thumbnails[annotation.id] = nil
        fullImages = fullImages.filter { !$0.key.hasPrefix(annotation.id.uuidString) }
        annotation.screenshots.forEach(store.deleteScreenshot(named:))
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
        fullImages = [:]
        setMode(annotations.isEmpty ? trayReturnMode : .tray)
    }

    func updateNote(_ id: UUID, to text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].note != note else { return }
        annotations[index].note = note
        persist()
    }

    /// One of the item's images at full size: the screenshot with its element outlined,
    /// or an attached image.
    func fullImage(for annotation: Annotation, at index: Int) -> UIImage? {
        guard annotation.screenshots.indices.contains(index) else { return nil }
        let key = "\(annotation.id.uuidString)-\(index)"
        if let cached = fullImages[key] { return cached }
        let url = store.draftDirectory.appending(path: annotation.screenshots[index])
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        // Keep only a few; a long session can collect many full-screen images.
        if fullImages.count >= 5 { fullImages.removeAll() }
        fullImages[key] = image
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
        case .noting, .viewer, .attaching:
            break
        }
    }

    // MARK: - Attachments

    /// Opens the attachment surface from the attachment button in the island.
    func openAttachments() {
        guard mode == .picking || mode == .tray else { return }
        levels = []
        setMode(.attaching)
    }

    func closeAttachments() {
        guard mode == .attaching else { return }
        setMode(.picking)
    }

    /// Attaches the app's screen as it is now, without the debugger.
    func attachThisScreen() {
        guard mode == .attaching else { return }
        let capture = captureScreen()
        beginAttachmentNote(PendingAttachment(kind: .screen, images: [capture.image], screen: capture.screen, sendsReport: false))
    }

    /// Attaches images chosen from Photos, together, as one item with one note. The note
    /// box opens at once with `previews`, and the full images take their place once loaded.
    func attachPhotos(previews: [UIImage], count: Int, loading: Task<[UIImage], Never>) {
        guard mode == .attaching, count > 0 else { return }
        beginAttachmentNote(PendingAttachment(kind: .photo, images: previews, screen: nil, sendsReport: false, count: count, loading: loading))
        Task {
            let images = await loading.value
            guard pending?.loading == loading else { return }
            guard !images.isEmpty else {
                logger.error("None of the chosen photos could be loaded")
                cancelNote()
                return
            }
            pending?.images = images
            pending?.count = images.count
            pending?.loading = nil
        }
    }

    // MARK: - Suggested screenshots

    /// Send under a suggested screenshot: write a note, then send it with the rest of the draft.
    func sendSuggestion() {
        guard let suggestion, mode == .idle || mode == .picking else { return }
        self.suggestion = nil
        let attachment = PendingAttachment(kind: suggestion.kind, images: [suggestion.image], screen: suggestion.screen, sendsReport: true)
        beginAttachmentNote(attachment, returningTo: mode)
    }

    func dismissSuggestion() {
        withAnimation(.smooth(duration: 0.3)) { suggestion = nil }
    }

    private func observeScreenshots() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerInAppScreenshot() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerRecentScreenshot() }
        })
    }

    /// A screenshot was just taken in the app. The system's picture includes the debugger,
    /// so the app's own windows are captured instead, at the same moment, without it.
    private func offerInAppScreenshot() {
        guard window != nil, mode == .idle || mode == .picking else { return }
        let capture = captureScreen()
        rememberInAppCapture(at: .now)
        offer(Suggestion(image: capture.image, kind: .screen, screen: capture.screen))
    }

    /// The newest screenshot taken in another app in the last 10 minutes, offered once,
    /// only when the app already has Photos access.
    private func offerRecentScreenshot() {
        guard window != nil, PhotoLibrary.canRead else { return }
        let assets = PhotoLibrary.newestScreenshots(limit: 1)
        let candidates = assets.compactMap { asset in
            asset.creationDate.map { ScreenshotSuggestion.Candidate(id: asset.localIdentifier, createdAt: $0) }
        }
        guard let pick = ScreenshotSuggestion.pick(newest: candidates, now: .now, offered: offeredPhotoIDs, inAppCaptures: inAppCaptureDates),
              let asset = assets.first(where: { $0.localIdentifier == pick.id })
        else { return }
        markOffered(pick.id)
        Task {
            guard let image = await PhotoLibrary.image(for: asset, pixels: PhotoLibrary.maxPixels),
                  mode == .idle || mode == .picking
            else { return }
            offer(Suggestion(image: image, kind: .photo, screen: nil))
        }
    }

    private func offer(_ suggestion: Suggestion) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { self.suggestion = suggestion }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let id = suggestion.id
        // A screenshot nobody acts on steps aside on its own.
        Task {
            try? await Task.sleep(for: .seconds(20))
            if self.suggestion?.id == id { dismissSuggestion() }
        }
    }

    private static let offeredPhotosKey = "AgenticDebuggingOfferedScreenshots"
    private static let inAppCapturesKey = "AgenticDebuggingInAppScreenshots"

    private var offeredPhotoIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.offeredPhotosKey) ?? [])
    }

    private func markOffered(_ id: String) {
        let ids = (UserDefaults.standard.stringArray(forKey: Self.offeredPhotosKey) ?? []) + [id]
        UserDefaults.standard.set(Array(ids.suffix(20)), forKey: Self.offeredPhotosKey)
    }

    /// When screenshots were taken in the app, so the same screenshot isn't offered
    /// again once it shows up in Photos.
    private var inAppCaptureDates: [Date] {
        (UserDefaults.standard.array(forKey: Self.inAppCapturesKey) as? [Double] ?? []).map(Date.init(timeIntervalSince1970:))
    }

    private func rememberInAppCapture(at date: Date) {
        let dates = (UserDefaults.standard.array(forKey: Self.inAppCapturesKey) as? [Double] ?? []) + [date.timeIntervalSince1970]
        UserDefaults.standard.set(Array(dates.suffix(10)), forKey: Self.inAppCapturesKey)
    }

    func send() {
        guard !annotations.isEmpty else { return }
        // The report takes the draft's files with it, so every image must be on disk first.
        let pending = writes
        writes = []
        Task {
            for write in pending { await write.value }
            saveReport()
        }
    }

    private func saveReport() {
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

    /// The top of an attached image, square, where a screen's title usually is.
    static func topSquare(of image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let side = min(cgImage.width, cgImage.height)
        let crop = CGRect(x: (cgImage.width - side) / 2, y: 0, width: side, height: side)
        return cgImage.cropping(to: crop).map { UIImage(cgImage: $0) }
    }

    /// A small picture of the item for the notes list: a close crop around its element,
    /// or the top of its first image.
    func thumbnail(for annotation: Annotation) -> UIImage? {
        if let cached = thumbnails[annotation.id] { return cached }
        guard let first = annotation.screenshots.first,
              let image = UIImage(contentsOfFile: store.draftDirectory.appending(path: first).path)
        else { return nil }
        let thumbnail = annotation.element.map { Self.crop(image, around: $0.frame, screenWidth: screenSize.width) } ?? Self.topSquare(of: image)
        guard let thumbnail else { return nil }
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

    /// While the debugger is idle only the floating button and a suggested screenshot
    /// take touches; the rest go to the app.
    func setTouchableFrame(_ frame: CGRect?, for name: String) {
        window?.touchableRects[name] = frame
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

    /// Encodes and writes images off the main thread, so closing the note box never waits
    /// on a large PNG or JPEG. The list and viewer read them back only after this finishes.
    private func writeImages(_ images: [UIImage], named names: [String], asPNG: Bool) {
        let store = store
        let logger = logger
        writes.append(Task.detached(priority: .userInitiated) {
            for (image, name) in zip(images, names) {
                do {
                    let data = asPNG ? image.pngData() : image.jpegData(compressionQuality: 0.85)
                    try store.saveScreenshot(data ?? Data(), named: name)
                } catch {
                    logger.error("Couldn't save an image: \(error.localizedDescription, privacy: .public)")
                }
            }
        })
    }

    private func beginAttachmentNote(_ attachment: PendingAttachment, returningTo next: Mode = .picking) {
        pending = attachment
        levels = []
        noteText = ""
        notingReturnMode = next
        beginNoting()
    }

    /// The app's screen as it is now, without the debugger, and the screen's name.
    private func captureScreen() -> (image: UIImage, screen: ScreenInfo) {
        let windows = appWindows()
        let bounds = window?.bounds ?? .zero
        let elements = AccessibilityTree.elements(in: windows, screenBounds: bounds)
        let screen = AccessibilityTree.screen(of: windows.first(where: \.isKeyWindow) ?? windows.last, elements: elements)
        return (AccessibilityTree.screenshot(of: windows, bounds: bounds), screen)
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
            guard let element = annotation.element, annotation.screen == screen,
                  let match = ElementSelection.match(element, in: elements)
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
