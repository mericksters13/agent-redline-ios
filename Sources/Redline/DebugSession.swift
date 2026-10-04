#if REDLINE && canImport(UIKit)
import os
import SwiftUI
import UIKit

/// Owns Redline for the life of the app: the overlay window, the floating
/// button, pick mode, attachments, suggested screenshots and the draft.
@MainActor
@Observable
final class DebugSession {
    static let shared = DebugSession()

    enum Mode {
        case idle, picking, noting, tray, viewer, attaching
        /// The reports already sent, opened with a long press on the floating button.
        case reports
        /// Picking where reports go: an agent on the Mac, then one of its chats.
        case destination
    }

    /// The Mac's answer to which chats a report can go to.
    enum ChatListState: Equatable {
        case loading
        case loaded(HubLink.ChatList)
        /// The Mac couldn't be reached; it will send the report to the chat in the worktree.
        case unavailable
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
    /// The attachment button's frame, where the photo panel grows from.
    var attachAnchor = CGRect.zero
    /// The screen just captured with the capture button, flying into the note box.
    private(set) var captureFlight: UIImage?
    /// Where the note box shows its first image: where a capture lands.
    var attachmentSlot = CGRect.zero
    /// The display's corner radius, so the annotate-mode frame can follow the screen's edge.
    private(set) var displayCornerRadius: CGFloat = 0
    /// Counts taps in pick mode that found nothing; each one shakes the island.
    private(set) var nudges = 0
    /// A short reminder under the island after such a tap.
    private(set) var hint: String?

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
    /// The project file that attached the kit. It names the worktree the app was built from,
    /// and keys the destination the user picked. Set once, when the overlay is installed.
    @ObservationIgnored private var sourceFile: String?
    @ObservationIgnored private var elements: [ElementSnapshot] = []
    @ObservationIgnored private var screenshot: UIImage?
    /// The main scroll view's position when the screen was read.
    @ObservationIgnored private var scrollState: ScrollState?
    /// Every screen notes were made on, with its captures: one picture per screen.
    @ObservationIgnored private var screens: [ScreenRecord] = []
    /// Captures loaded from disk, kept while they're in use.
    @ObservationIgnored private var captureImages: [UUID: UIImage] = [:]
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
    @ObservationIgnored private let logger = Logger(subsystem: "Redline", category: "session")

    private init() {}

    // MARK: - Install

    /// Installs the overlay in `scene`. Only the first call does anything: the overlay lives in
    /// one scene, and the first attachment's source file is the one reports carry.
    func install(in scene: UIWindowScene, sourceFile: String) {
        guard window == nil else { return }
        self.sourceFile = sourceFile
        destination = savedDestination()
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
        displayCornerRadius = Self.displayCornerRadius(of: scene.screen)

        annotations = store.loadDraft()
        screens = store.loadScreens()
        observeKeyboard()
        observeScreenshots()
        // On a cold launch the app became active before Redline was installed.
        Task {
            try? await Task.sleep(for: .seconds(1))
            offerRecentScreenshot()
            offerUndeliveredReports()
        }

        // Launch arguments for checking layouts on a device without touching it:
        // -RedlinePickOnLaunch YES opens pick mode, -RedlinePickPoint "0.5,0.8"
        // then picks the element at that fraction of the screen, and
        // -RedlineNoteText "..." fills in the note. -RedlineOpenViewer YES
        // opens the viewer on the first saved note. -RedlineOpenAttachments YES opens
        // the attachment surface, and -RedlineSimulateScreenshot YES acts as if a
        // screenshot was taken, which a simulator can't do from the command line.
        let defaults = UserDefaults.standard
        // -RedlineLaunchDelay waits that many seconds first, for apps that load slowly.
        let launchDelay = max(defaults.double(forKey: "RedlineLaunchDelay"), 1)
        if defaults.bool(forKey: "RedlineOpenViewer") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                enterPicking()
                try? await Task.sleep(for: .milliseconds(300))
                toggleTray()
                if let first = annotations.first { openViewer(first) }
            }
        }
        if defaults.bool(forKey: "RedlineOpenAttachments") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                enterPicking()
                try? await Task.sleep(for: .milliseconds(400))
                openAttachments()
            }
        }
        if defaults.bool(forKey: "RedlineSimulateScreenshot") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: UIApplication.shared)
            }
        }
        if defaults.bool(forKey: "RedlinePickOnLaunch") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                enterPicking()
                try? await Task.sleep(for: .milliseconds(300))
                let point: (String) -> CGPoint? = { key in
                    let parts = defaults.string(forKey: key)?.split(separator: ",").compactMap { Double($0) }
                    guard let parts, parts.count == 2 else { return nil }
                    return CGPoint(x: parts[0] * self.screenSize.width, y: parts[1] * self.screenSize.height)
                }
                // -RedlineHoverPoint holds a finger-down hover there instead of picking.
                if let hover = point("RedlineHoverPoint") {
                    self.hover(at: hover)
                    return
                }
                guard let pick = point("RedlinePickPoint") else { return }
                finishHover(at: pick)
                if let text = defaults.string(forKey: "RedlineNoteText") { noteText = text }
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
        guard selected != nil else {
            nudge()
            return
        }
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
        let captureID = fileCapture(screenshot)
        thumbnails[id] = Self.crop(screenshot, around: element.frame, screenWidth: screenSize.width)
        annotations.append(Annotation(
            id: id,
            createdAt: .now,
            note: note,
            kind: .element,
            element: element,
            ancestors: Array(levels.dropFirst(levelIndex + 1)),
            screen: screen,
            screenshots: [],
            captureID: captureID
        ))
        pruneCaptures()
        fullImages = [:]
        persist()
        levels = []
        refreshMarkers()
        endNoting(returningTo: notingReturnMode)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func cancelNote() {
        levels = []
        captureFlight = nil
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
        // Other notes on the same screen show this one's outline, so their pictures are redrawn.
        fullImages = [:]
        annotation.screenshots.forEach(store.deleteScreenshot(named:))
        pruneCaptures()
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

    // MARK: - Sent reports

    func openSentReports() {
        guard mode == .idle, window != nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        setMode(.reports)
    }

    func closeSentReports() {
        guard mode == .reports else { return }
        setMode(.idle)
    }

    /// The reports already sent, newest first, read off the main thread.
    func sentReports() async -> [SentReport] {
        let store = store
        return await Task.detached(priority: .userInitiated) { store.sentReports() }.value
    }

    /// The last attempt to hand reports to the Mac.
    func lastDelivery() -> Delivery? {
        store.lastDelivery()
    }

    func updateNote(_ id: UUID, to text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].note != note else { return }
        annotations[index].note = note
        persist()
    }

    /// One of the item's images at full size: its screen's picture with every note on it
    /// outlined and this one standing out, or an attached image.
    func fullImage(for annotation: Annotation, at index: Int) -> UIImage? {
        if let captureID = annotation.captureID { return screenPicture(for: annotation, on: captureID) }
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
        case .noting, .viewer, .attaching, .reports, .destination:
            break
        }
    }

    // MARK: - Attachments

    /// Opens the photo panel from the attachment button in the island.
    func openAttachments() {
        guard mode == .picking || mode == .tray else { return }
        levels = []
        setMode(.attaching)
    }

    func closeAttachments() {
        guard mode == .attaching else { return }
        setMode(.picking)
    }

    /// The capture button: takes the app's screen as it is now, without Redline, the
    /// way a screenshot is taken, and opens the note box for it.
    func captureThisScreen() {
        guard mode == .picking || mode == .tray else { return }
        let capture = captureScreen()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        captureFlight = capture.image
        beginAttachmentNote(PendingAttachment(kind: .screen, images: [capture.image], screen: capture.screen, sendsReport: false))
    }

    /// The captured screen has landed in the note box.
    func finishCaptureFlight() {
        captureFlight = nil
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
            MainActor.assumeIsolated {
                self?.offerRecentScreenshot()
                self?.offerUndeliveredReports()
            }
        })
    }

    /// A screenshot was just taken in the app. The system's picture includes Redline,
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

    // MARK: - Handing reports to the Mac

    /// Set once a report has reached the Mac's hub, and so iOS has allowed local network access.
    nonisolated static let hubReachedKey = "RedlineHubReached"

    /// Sends every report the Mac hasn't confirmed to its hub, notes the ones it now has, and
    /// records how it went. Nil when there's nothing to send.
    nonisolated static func deliverReports(from store: ReportStore, patience: TimeInterval) async -> HubLink.Outcome? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let reports = store.undeliveredReports()
        guard !reports.isEmpty else { return nil }
        guard let address = store.hubAddress() else {
            store.recordDelivery(.noHub)
            return .noHub
        }
        // In a simulator the hub takes reports from the app's folder as they're saved.
        if address.uploads == false {
            store.markDelivered(reports.map(\.id))
            store.recordDelivery(.delivered)
            return .delivered
        }
        let result = await HubLink.deliver(reports, bundleID: bundleID, address: address, files: { store.reportFiles($0) }, patience: patience)
        store.markDelivered(result.delivered)
        store.recordDelivery(result.outcome)
        // The hub answered, so iOS has allowed local network access.
        if result.outcome != .unreachable { UserDefaults.standard.set(true, forKey: hubReachedKey) }
        return result.outcome
    }

    /// What the toast after Send says, so a report that didn't reach the Mac says why.
    nonisolated static func toast(for outcome: HubLink.Outcome?, notes: String, to destination: String? = nil) -> String {
        switch outcome {
        case .delivered: "Sent \(notes) to \(destination ?? "the Mac")"
        case .noHub, nil: "Saved \(notes) on this iPhone"
        case .unreachable: "Saved on this iPhone. Couldn't reach the Mac"
        case .refused: "Saved on this iPhone. The Mac didn't accept it"
        case .interrupted: "Saved on this iPhone. Sending to the Mac stopped"
        }
    }

    /// When the app comes back, offers what the Mac hasn't confirmed, such as a report sent from
    /// another network. Only after a report has reached the hub once, so iOS's local network
    /// question is never asked at launch.
    private func offerUndeliveredReports() {
        guard UserDefaults.standard.bool(forKey: Self.hubReachedKey) else { return }
        let store = store
        Task.detached(priority: .utility) {
            _ = await DebugSession.deliverReports(from: store, patience: 8)
        }
    }

    private static let offeredPhotosKey = "RedlineOfferedScreenshots"
    private static let inAppCapturesKey = "RedlineInAppScreenshots"

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

    // MARK: - Where reports go

    /// Where reports from this build go, as the user picked. Kept per worktree the app was built
    /// from, so a build from another worktree starts with that worktree's chat.
    /// Loaded when the overlay is installed, once the source file that keys it is known.
    private(set) var destination: Report.Destination?
    private(set) var chatList: ChatListState = .loading
    /// The agent whose chats the picker shows.
    var pickerAgent: String?
    /// What's selected in the picker: a chat, or a new chat when `chat` is nil.
    var pickerChoice: Report.Destination?
    /// The picker opened from Send: confirming it sends the report.
    private(set) var sendsAfterPicking = false
    private var modeBeforePicking: Mode = .picking

    /// The hub has set this app up, so there are chats to pick from.
    var canPickDestination: Bool { store.hubAddress() != nil }

    private var destinationKey: String {
        "RedlineDestination|" + (sourceFile ?? Bundle.main.bundleIdentifier ?? "")
    }

    private func savedDestination() -> Report.Destination? {
        UserDefaults.standard.data(forKey: destinationKey).flatMap { try? JSONDecoder().decode(Report.Destination.self, from: $0) }
    }

    /// Opens the picker and asks the Mac for its chats. `thenSend` when opened from Send.
    func openDestinations(thenSend: Bool = false) {
        sendsAfterPicking = thenSend
        modeBeforePicking = mode == .noting || mode == .destination ? .picking : mode
        pickerChoice = destination
        pickerAgent = destination?.agent
        chatList = .loading
        setMode(.destination)
        guard let address = store.hubAddress(), let bundleID = Bundle.main.bundleIdentifier else {
            chatList = .unavailable
            return
        }
        // The first time, iOS asks about local network access before the hub can answer.
        let patience: TimeInterval = UserDefaults.standard.bool(forKey: Self.hubReachedKey) ? 8 : 60
        let sourceFile = sourceFile
        Task {
            let list = await HubLink.chats(bundleID: bundleID, address: address, sourceFile: sourceFile, patience: patience)
            guard mode == .destination else { return }
            guard let list else {
                chatList = .unavailable
                return
            }
            UserDefaults.standard.set(true, forKey: Self.hubReachedKey)
            chatList = .loaded(list)
            // A saved chat that closed isn't offered; the chat in the build's worktree is.
            if let choice = pickerChoice, let chat = choice.chat, !list.chats.contains(where: { $0.id == chat && $0.agent == choice.agent }) {
                pickerChoice = nil
            }
            if pickerChoice == nil, let here = list.chats.first(where: \.sameWorktree) {
                pickerChoice = Report.Destination(agent: here.agent, chat: here.id, title: here.title)
            }
            if pickerAgent == nil || !list.agents.contains(pickerAgent ?? "") {
                pickerAgent = pickerChoice?.agent ?? list.agents.first
            }
        }
    }

    func choose(agent: String) {
        pickerAgent = agent
    }

    /// Picking "New chat" names a fresh pick, so the next report starts a new chat even if the
    /// last pick was a new chat too.
    func choose(_ choice: Report.Destination) {
        var choice = choice
        if choice.chat == nil { choice.newChat = UUID().uuidString }
        pickerChoice = choice
    }

    /// Keeps the pick and, when the picker opened from Send, sends.
    func confirmDestination() {
        if let choice = pickerChoice {
            destination = choice
            if let data = try? JSONEncoder().encode(choice) { UserDefaults.standard.set(data, forKey: destinationKey) }
        }
        let thenSend = sendsAfterPicking
        sendsAfterPicking = false
        setMode(modeBeforePicking)
        if thenSend { send(pickingFirst: false) }
    }

    func cancelDestinations() {
        sendsAfterPicking = false
        setMode(modeBeforePicking)
    }

    /// Sends the draft. The first time, the user picks where reports go; after that they go
    /// there at once.
    func send(pickingFirst: Bool = true) {
        guard !annotations.isEmpty else { return }
        if pickingFirst, destination == nil, canPickDestination {
            openDestinations(thenSend: true)
            return
        }
        // The report takes the draft's files with it, so every image must be on disk first.
        let pending = writes
        writes = []
        Task {
            for write in pending { await write.value }
            saveReport()
        }
    }

    /// Moves the draft into a report folder at once, so new notes start a fresh draft, then
    /// draws the report's pictures in the background.
    private func saveReport() {
        guard !annotations.isEmpty else { return }
        let date = Date.now
        let started: (id: String, folder: URL, draft: URL)
        do {
            started = try store.beginReport(date: date)
        } catch {
            logger.error("Couldn't start the report: \(error.localizedDescription, privacy: .public)")
            show(toast: "Couldn't save the report")
            return
        }
        let destination = destination
        let input = ReportBuilder.Input(
            id: started.id, date: date, app: .current(sourceFile: sourceFile), device: .current,
            annotations: annotations, screens: screens, draft: started.draft, folder: started.folder,
            destination: destination
        )
        let count = annotations.count
        annotations = []
        screens = []
        thumbnails = [:]
        fullImages = [:]
        captureImages = [:]
        levels = []
        markers = []
        elements = []
        screenshot = nil
        setMode(.idle)

        let store = store
        let logger = logger
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try ReportBuilder.build(input)
                try store.finishReport(report, in: started.folder)
                logger.notice("Report saved at \(started.folder.path, privacy: .public)")
                // The first time, iOS asks about local network access before the hub can answer.
                let patience: TimeInterval = UserDefaults.standard.bool(forKey: DebugSession.hubReachedKey) ? 8 : 60
                let outcome = await DebugSession.deliverReports(from: store, patience: patience)
                let notes = count == 1 ? "1 note" : "\(count) notes"
                await self?.show(toast: DebugSession.toast(for: outcome, notes: notes, to: destination?.title))
            } catch {
                logger.error("Couldn't save the report: \(error.localizedDescription, privacy: .public)")
                await self?.show(toast: "Couldn't save the report")
            }
        }
    }

    // MARK: - One picture per screen

    /// Files the screen as just read under its screen, so every screen has one picture:
    /// reuses the screen's picture when nothing changed, stitches the new capture in when
    /// the screen scrolled, and otherwise makes the new capture the screen's picture and
    /// moves the earlier notes onto it wherever their elements can be found again.
    /// Returns the capture the new note belongs to.
    private func fileCapture(_ image: UIImage) -> UUID {
        var capture = Capture(
            id: UUID(), file: "capture-\(UUID().uuidString).png", size: screenSize,
            scroll: scrollState, elements: elements, group: 0
        )
        guard let index = screens.firstIndex(where: { $0.info == screen }), let previous = screens[index].captures.last else {
            screens.append(ScreenRecord(id: UUID(), info: screen, captures: [capture]))
            keep(capture, image)
            return capture.id
        }
        let before = captureImage(previous)
        let picturesMatch = before?.cgImage.flatMap { old in
            image.cgImage.map { PictureComparison.difference(old, $0) < PictureComparison.samePicture }
        } ?? false
        let overlap = overlapMatches(previous: previous, before: before, new: capture, after: image)

        switch CaptureMerge.decide(previous: previous, new: capture, picturesMatch: picturesMatch, overlapMatches: overlap) {
        case .reuse(let existing):
            return existing
        case .stitch:
            capture.group = previous.group
            screens[index].captures.append(capture)
            keep(capture, image)
            return capture.id
        case .replace:
            capture.group = previous.group + 1
            screens[index].captures.append(capture)
            keep(capture, image)
            let screenCaptures = screens[index].captures
            let onScreen = CGRect(origin: .zero, size: screenSize)
            for i in annotations.indices {
                // An earlier note moves onto the new picture only if its element is still
                // there and still looks the same. Under a popup or a dimmed backdrop it doesn't,
                // and the note keeps the picture it was made on, as an earlier state.
                guard let old = annotations[i].captureID, old != capture.id,
                      let oldCapture = screenCaptures.first(where: { $0.id == old }),
                      let element = annotations[i].element,
                      let match = ElementSelection.match(element, in: capture.elements),
                      onScreen.contains(match.frame.insetBy(dx: 1, dy: 1)),
                      looksTheSame(element.frame, in: oldCapture, as: match.frame, in: image)
                else { continue }
                annotations[i].captureID = capture.id
                annotations[i].element?.frame = match.frame
                thumbnails[annotations[i].id] = nil
            }
            return capture.id
        }
    }

    /// Whether the content two captures of a scrolled screen share looks the same; nil when
    /// they share too little to tell.
    private func overlapMatches(previous: Capture, before: UIImage?, new: Capture, after: UIImage) -> Bool? {
        guard let from = previous.scroll, let to = new.scroll, from.isSameView(as: to),
              let band = ScreenComposition.band(for: [previous, new]),
              let old = before?.cgImage, let current = after.cgImage else { return nil }
        let low = max(from.contentY(ofScreenY: band.lowerBound), to.contentY(ofScreenY: band.lowerBound))
        let high = min(from.contentY(ofScreenY: band.upperBound), to.contentY(ofScreenY: band.upperBound))
        guard high - low >= 40 else { return nil }
        func pixelRows(_ scroll: ScrollState, in image: CGImage) -> Range<Int> {
            let ratio = CGFloat(image.width) / screenSize.width
            return Int((scroll.screenY(ofContentY: low) * ratio).rounded())..<Int((scroll.screenY(ofContentY: high) * ratio).rounded())
        }
        return PictureComparison.difference(old, rows: pixelRows(from, in: old), current, rows: pixelRows(to, in: current))
            < PictureComparison.sameOverlap
    }

    /// Whether an element looks the same in an earlier capture and in the new screen.
    private func looksTheSame(_ frame: CGRect, in capture: Capture, as newFrame: CGRect, in image: UIImage) -> Bool {
        guard let old = captureImage(capture)?.cgImage, let new = image.cgImage else { return false }
        func pixels(_ rect: CGRect, of picture: CGImage, width: CGFloat) -> CGRect {
            let ratio = CGFloat(picture.width) / width
            return CGRect(x: rect.minX * ratio, y: rect.minY * ratio, width: rect.width * ratio, height: rect.height * ratio)
        }
        return PictureComparison.difference(
            old, in: pixels(frame, of: old, width: capture.size.width),
            new, in: pixels(newFrame, of: new, width: screenSize.width)
        ) < PictureComparison.sameElement
    }

    private func keep(_ capture: Capture, _ image: UIImage) {
        captureImages[capture.id] = image
        writeImages([image], named: [capture.file], asPNG: true)
    }

    private func captureImage(_ capture: Capture) -> UIImage? {
        if let cached = captureImages[capture.id] { return cached }
        guard let image = UIImage(contentsOfFile: store.draftDirectory.appending(path: capture.file).path) else { return nil }
        captureImages[capture.id] = image
        return image
    }

    private func capture(withID id: UUID) -> (record: ScreenRecord, capture: Capture)? {
        for record in screens {
            if let capture = record.captures.first(where: { $0.id == id }) { return (record, capture) }
        }
        return nil
    }

    /// Drops captures no note points at any more, and screens with no captures left.
    private func pruneCaptures() {
        let used = Set(annotations.compactMap(\.captureID))
        for index in screens.indices.reversed() {
            for capture in screens[index].captures where !used.contains(capture.id) {
                store.deleteScreenshot(named: capture.file)
                captureImages[capture.id] = nil
            }
            screens[index].captures.removeAll { !used.contains($0.id) }
            if screens[index].captures.isEmpty { screens.remove(at: index) }
        }
    }

    /// The capture a note was made on, with every note of its screen that's in view
    /// outlined and numbered, the note itself standing out.
    private func screenPicture(for annotation: Annotation, on captureID: UUID) -> UIImage? {
        let key = "\(annotation.id.uuidString)-screen"
        if let cached = fullImages[key] { return cached }
        guard let (record, capture) = capture(withID: captureID), let image = captureImage(capture),
              let plan = ScreenComposition.plan(for: [capture]) else { return nil }
        let group = record.captures.filter { $0.group == capture.group }
        let band = ScreenComposition.band(for: group)
        let outlines = annotations.enumerated().compactMap { index, other -> ReportRenderer.Outline? in
            guard let otherCapture = other.captureID.flatMap({ id in group.first { $0.id == id } }),
                  let frame = other.element?.frame,
                  let rect = ScreenComposition.position(of: frame, from: otherCapture, on: capture, band: band)
            else { return nil }
            return ReportRenderer.Outline(number: index + 1, rect: rect, style: other.id == annotation.id ? .current : .quiet)
        }
        let picture = ReportRenderer.render(plan, pictures: [capture.id: image], outlines: outlines, scale: 2)
        if fullImages.count >= 5 { fullImages.removeAll() }
        fullImages[key] = picture
        return picture
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
        if let captureID = annotation.captureID, let element = annotation.element {
            guard let (_, capture) = capture(withID: captureID), let image = captureImage(capture),
                  let thumbnail = Self.crop(image, around: element.frame, screenWidth: capture.size.width)
            else { return nil }
            thumbnails[annotation.id] = thumbnail
            return thumbnail
        }
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

    private static let keyboardHeightKey = "RedlineKeyboardHeight"

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

    /// While Redline is idle only the floating button and a suggested screenshot
    /// take touches; the rest go to the app.
    func setTouchableFrame(_ frame: CGRect?, for name: String) {
        window?.touchableRects[name] = frame
    }

    private static let buttonPositionKey = "RedlineButtonPosition"

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

    /// A tap in pick mode that found nothing: the app didn't respond because Redline has
    /// the screen. Says so, rather than leaving the tester to think the app is broken.
    private func nudge() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        withAnimation(.linear(duration: 0.4)) { nudges += 1 }
        withAnimation(.smooth(duration: 0.25)) { hint = "Annotate mode" }
        UIAccessibility.post(notification: .announcement, argument: "Annotate mode. Close it to use the app.")
        let count = nudges
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if nudges == count { withAnimation(.smooth(duration: 0.3)) { hint = nil } }
        }
    }

    /// The display's corner radius, read through a private key; square corners when it
    /// can't be read. Debug builds only, like the rest of the kit.
    private static func displayCornerRadius(of screen: UIScreen) -> CGFloat {
        let key = "_displayCornerRadius"
        guard screen.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (screen.value(forKey: key) as? CGFloat) ?? 0
    }

    /// Keyboard focus moves to Redline when it leaves idle and back to the app when
    /// it returns to idle, never in between: the first tap after each handoff gets lost,
    /// so handing focus back and forth around every note cost a tap each time.
    private func setMode(_ newMode: Mode) {
        let wasIdle = mode == .idle
        mode = newMode
        if newMode != .picking { hint = nil }
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

    /// The app's screen as it is now, without Redline, and the screen's name.
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
        scrollState = AccessibilityTree.mainScrollState(in: appWindows, screenBounds: window.bounds)
        refreshMarkers()
    }

    private func persist() {
        do {
            try store.saveDraft(annotations)
            try store.saveScreens(screens)
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

    /// The app's own visible windows, bottom to top, without Redline's.
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
    /// This app, built from the project that holds `sourceFile`.
    static func current(sourceFile: String?) -> Report.App {
        let info = Bundle.main.infoDictionary ?? [:]
        return Report.App(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            sourceFile: sourceFile
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
