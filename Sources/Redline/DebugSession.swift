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

    /// What Redline is doing, which decides what the overlay shows and whether it takes touches.
    enum Mode {
        case idle, picking, noting, tray, viewer, attaching
        /// The reports already sent, opened with a long press on the floating button.
        case reports
        /// Choosing where reports go: an agent on the Mac, then one of its chats.
        case destination

        /// Annotate mode in any of its states: Redline has the screen, which shows the
        /// annotate frame and the markers of notes already made.
        var isAnnotating: Bool {
            switch self {
            case .picking, .noting, .tray, .attaching: true
            case .idle, .viewer, .reports, .destination: false
            }
        }

        /// The island of pick-mode controls shows.
        var showsIsland: Bool {
            switch self {
            case .picking, .tray, .attaching: true
            case .idle, .noting, .viewer, .reports, .destination: false
            }
        }
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
        ///
        /// Saved with the note.
        var images: [UIImage]
        /// The note box's thumbnails of the first few images, at the size they're shown.
        var previews: [UIImage]
        var screen: ScreenInfo?
        /// True for a suggested screenshot: its note box sends the report.
        var sendsReport: Bool
        /// How many images, known before they finish loading.
        var count = 1
        /// The full-size images, while they load.
        ///
        /// The note box opens without waiting for them.
        var loading: Task<[UIImage], Never>?
        /// Tells this attachment from one started later, after this one was cancelled.
        let id = UUID()
        /// True while Add note waits for photos that are still loading.
        var isSaving = false
    }

    /// A screenshot offered at the side of the screen.
    struct Suggestion: Identifiable {
        let id = UUID()
        var image: UIImage
        /// The card's preview, at the size it's shown.
        ///
        /// The full image is kept for sending.
        var preview: UIImage
        var kind: Annotation.Kind
        var screen: ScreenInfo?
    }

    /// A note already made on the screen being picked on, where its element is now.
    struct Marker: Identifiable, Equatable {
        var id: UUID
        var number: Int
        var frame: CGRect
    }

    /// A short message under the island, or at the top of the screen when idle.
    struct Toast: Equatable {
        var message: String
        var isError = false
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
    private(set) var toast: Toast?
    private(set) var screenSize = CGSize.zero
    private(set) var safeAreaInsets = UIEdgeInsets.zero
    private(set) var keyboardTop = CGFloat.infinity
    /// True from the moment the note card asks for the keyboard until the keyboard
    /// reports its frame, so the card can open where it will end up.
    private(set) var isAwaitingKeyboard = false
    /// Center of the floating button, in screen points.
    ///
    /// Nil until the window has a size.
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
    /// Why the last Add note failed, shown on the note card.
    private(set) var noteError: String?
    /// The window size when the screen was last read.
    private(set) var readSize = CGSize.zero

    /// False after the window changes size, such as on rotation, until the screen is read
    /// again: element frames from the last read no longer line up with the screen.
    var screenReadIsCurrent: Bool { readSize == screenSize }

    /// Where reports from this build go, as the user picked.
    ///
    /// Kept per worktree the app was built from, so a build from another worktree starts with that
    /// worktree's chat. Loaded when the overlay is installed, once the source file that keys it is
    /// known.
    private(set) var destination: Report.Destination?
    private(set) var chatList: ChatListState = .loading
    /// The agent whose chats the picker shows.
    private(set) var pickerAgent: String?
    /// What's selected in the picker: a chat, or a new chat when `chat` is nil.
    private(set) var pickerChoice: Report.Destination?
    /// The picker opened from Send: confirming it sends the report.
    private(set) var sendsAfterChoosingDestination = false
    private var modeBeforeDestinations: Mode = .picking

    /// The hub's address, read from disk at set points (install, activation, opening the notes,
    /// Send and the picker) rather than on every redraw.
    ///
    /// The Mac writes it once, at setup.
    private(set) var hubAddress: HubLink.Address?

    var safeAreaTop: CGFloat { safeAreaInsets.top }

    var selected: ElementSnapshot? {
        levels.indices.contains(levelIndex) ? levels[levelIndex] : nil
    }

    var canStepUp: Bool { levelIndex + 1 < levels.count }
    var canStepDown: Bool { levelIndex > 0 }

    var screenTitle: String { screen.title ?? "This screen" }

    /// The number the note being written will get.
    var nextNumber: Int { annotations.count + 1 }

    /// The hub has set this app up, so there are chats to pick from.
    var canPickDestination: Bool { hubAddress != nil }

    @ObservationIgnored private var window: OverlayWindow?
    /// The project file that attached the kit.
    ///
    /// It names the worktree the app was built from, and keys the destination the user picked. Set
    /// once, when the overlay is installed.
    @ObservationIgnored private var sourceFile: String?
    @ObservationIgnored private var elements: [ElementSnapshot] = []
    @ObservationIgnored private var screenImage: UIImage?
    /// The main scroll view's position when the screen was read.
    @ObservationIgnored private var scrollState: ScrollState?
    /// Every screen notes were made on, with its captures: one snapshot per state of a screen.
    @ObservationIgnored private var screens: [ScreenRecord] = []
    /// Captures loaded from disk, kept while they're in use.
    @ObservationIgnored private var captureImages: [UUID: UIImage] = [:]
    @ObservationIgnored private var appKeyWindow: UIWindow?
    @ObservationIgnored private var trayReturnMode = Mode.idle
    /// Where Cancel or Add on the note card goes back to.
    @ObservationIgnored private var notingReturnMode = Mode.picking
    /// Notes added since pick mode opened on the screen showing now.
    ///
    /// The user can't move the app while the debugger takes every touch, so these are on the
    /// current screen even when it has no title, until a read finds another screen.
    @ObservationIgnored private var notesThisVisit: Set<UUID> = []
    /// The view controller showing the screen that was last read.
    @ObservationIgnored private weak var screenController: UIViewController?
    /// The view controller each note made since launch was taken on.
    ///
    /// Held weakly, so once that screen closes its notes match no other screen, even one with the
    /// same title.
    @ObservationIgnored private let noteControllers = NSMapTable<NSUUID, UIViewController>.strongToWeakObjects()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var thumbnails: [UUID: UIImage] = [:]
    /// Full-size images for the viewer, kept for the few around the one showing.
    @ObservationIgnored private let fullImages: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // The page showing and its neighbors, with room for one more.
        cache.countLimit = 6
        return cache
    }()
    /// Images still being written to the draft.
    ///
    /// Send waits for them.
    @ObservationIgnored private var writes: [Task<Void, Never>] = []
    /// The send in progress, waiting for the draft's images before it saves the report.
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// The question to the Mac about which chats a report can go to, while it's open.
    @ObservationIgnored private var chatsRequest: Task<Void, Never>?
    /// Each timer is replaced when it starts again, so an older one never cuts a newer one short.
    @ObservationIgnored private var toastTimer: Task<Void, Never>?
    @ObservationIgnored private var hintTimer: Task<Void, Never>?
    @ObservationIgnored private var keyboardWait: Task<Void, Never>?
    @ObservationIgnored private var suggestionTimer: Task<Void, Never>?
    /// True while a finger is down in pick mode.
    @ObservationIgnored private var isTouchDown = false
    /// Waits for scrolling to settle after pick mode opens, then reads the screen; nil once read.
    @ObservationIgnored private var settling: Task<Void, Never>?
    /// The latest touch made while `settling` runs, replayed against its read.
    @ObservationIgnored private var settlingTouch: (point: CGPoint, isLifted: Bool)?
    @ObservationIgnored private let store = ReportStore.standard
    @ObservationIgnored private let selectionFeedback = UISelectionFeedbackGenerator()
    @ObservationIgnored private let logger = Log.session

    private init() {}

    // MARK: - Install

    /// Installs the overlay in `scene`.
    ///
    /// The first call builds the overlay, and its attachment's source file is the one reports
    /// carry. UIKit can disconnect a scene and later connect a new one while the app keeps
    /// running: a later call then moves the overlay to the new scene with its draft and state.
    /// While its own scene is still connected, it stays there.
    func install(in scene: UIWindowScene, sourceFile: String) {
        if let window {
            if window.windowScene.map({ $0.activationState == .unattached }) ?? true {
                appKeyWindow = nil
                window.windowScene = scene
                window.isHidden = false
            }
            return
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            ReportStore.moveSettingsFromOldName(in: .standard, domain: bundleID)
        }
        self.sourceFile = sourceFile
        destination = savedDestination()
        refreshHubAddress()
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

        // A report cut short last time, such as by the app being killed while it was drawn, puts
        // its notes back in the draft.
        store.recoverInterruptedReports()
        annotations = loadDraftFile(store.draftFile, named: "notes") { try store.loadDraft() }
        screens = loadDraftFile(store.screensFile, named: "screens") { try store.loadScreens() }
        observeKeyboard()
        observeScreenshots()
        // On a cold launch the app became active before Redline was installed.
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
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
                guard !Task.isCancelled else { return }
                enterPicking()
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                toggleTray()
                if let first = annotations.first { openViewer(first) }
            }
        }
        if defaults.bool(forKey: "RedlineOpenAttachments") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                guard !Task.isCancelled else { return }
                enterPicking()
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                openAttachments()
            }
        }
        if defaults.bool(forKey: "RedlineSimulateScreenshot") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                guard !Task.isCancelled else { return }
                NotificationCenter.default.post(
                    name: UIApplication.userDidTakeScreenshotNotification,
                    object: UIApplication.shared
                )
            }
        }
        if defaults.bool(forKey: "RedlinePickOnLaunch") {
            Task {
                try? await Task.sleep(for: .seconds(launchDelay))
                guard !Task.isCancelled else { return }
                enterPicking()
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
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

    /// Loads one of the draft's files.
    ///
    /// One that can't be read is moved aside before anything can save over it, and the draft starts
    /// without it.
    private func loadDraftFile<Item>(_ file: URL, named name: String, load: () throws -> [Item]) -> [Item] {
        do {
            return try load()
        } catch {
            logger.error(
                "Couldn't read the draft's \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            do {
                let aside = try store.setAsideUnreadable(file)
                logger.notice("Kept the unreadable file at \(aside.path(percentEncoded: false), privacy: .private)")
            } catch {
                logger.error("Couldn't move the unreadable file aside: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
    }

    // MARK: - Pick mode

    func enterPicking() {
        guard mode == .idle, window != nil else { return }
        // A list still moving would leave every outline behind once the screen is read. A fling
        // the user started is stopped where it is. A scroll the app animates itself is left to
        // reach the place the app sent it, so wait, up to half a second, until no scroll view
        // moves from one frame to the next.
        let scrollViews = AppWindows.scrollViews(in: appWindows())
        AppWindows.stopScrolling(scrollViews)
        levels = []
        notesThisVisit = []
        setMode(.picking)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        settling?.cancel()
        settlingTouch = nil
        settling = Task {
            try? await Task.sleep(for: .milliseconds(60))
            var positions = AppWindows.scrollPositions(of: scrollViews)
            for _ in 0..<27 where !Task.isCancelled && mode == .picking {
                try? await Task.sleep(for: .milliseconds(16))
                let next = AppWindows.scrollPositions(of: scrollViews)
                if next == positions { break }
                positions = next
            }
            guard !Task.isCancelled else { return }
            settling = nil
            guard mode == .picking else { return }
            // A touch made while the screen settled picks from this read, not a moving one.
            let touch = settlingTouch
            settlingTouch = nil
            if let touch, touch.isLifted {
                finishHover(at: touch.point)
            } else if let touch {
                hover(at: touch.point)
            } else {
                readScreen()
            }
        }
    }

    func exitPicking() {
        guard mode == .picking || mode == .tray else { return }
        settling?.cancel()
        settling = nil
        settlingTouch = nil
        levels = []
        markers = []
        elements = []
        screenImage = nil
        setMode(.idle)
    }

    func hover(at point: CGPoint) {
        guard mode == .picking else { return }
        if settling != nil {
            settlingTouch = (point, false)
            return
        }
        if !isTouchDown {
            // Each new touch reads the screen again, so positions, saved-note markers
            // and the report snapshot match what is on screen right now.
            isTouchDown = true
            readScreen()
        }
        let found = ElementSelection.levels(at: point, in: elements, screenSize: screenSize)
        if found.first != levels.first, found.first != nil {
            selectionFeedback.selectionChanged()
        }
        // Called on every frame of a drag: publish only what changed.
        if found != levels { levels = found }
        if levelIndex != 0 { levelIndex = 0 }
    }

    func finishHover(at point: CGPoint) {
        if mode == .picking, settling != nil {
            settlingTouch = (point, true)
            return
        }
        hover(at: point)
        isTouchDown = false
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
            guard !pending.isSaving else { return }
            guard let loading = pending.loading else {
                saveAttachment(pending, note: note)
                return
            }
            // Photos still loading: save once they're in. The note box stays until then.
            self.pending?.isSaving = true
            let id = pending.id
            Task {
                let images = await loading.value
                // Cancelled, or another attachment started while the photos loaded.
                guard var ready = self.pending, ready.id == id else { return }
                // None loaded: attachPhotos's own task cancels the note.
                guard !images.isEmpty else { return }
                // Fewer images than were chosen: the note box stays open and says so, so Add
                // saves the rest only once the user has seen which are missing.
                guard images.count == pending.count else {
                    self.pending?.isSaving = false
                    return
                }
                ready.images = images
                ready.loading = nil
                saveAttachment(ready, note: note)
            }
            return
        }
        guard let element = selected, let screenImage else { return }
        let id = UUID()
        // Filing the capture can move earlier notes onto it, so keep what to put back if the
        // draft can't be written.
        let before = (annotations: annotations, screens: screens)
        let captureID = fileCapture(screenImage, for: element)
        let annotation = Annotation(
            id: id,
            createdAt: .now,
            note: note,
            kind: .element,
            element: element,
            ancestors: Array(levels.dropFirst(levelIndex + 1)),
            screen: screen,
            attachments: [],
            captureID: captureID
        )
        // A failed save keeps the card open with the text for another try: a note missing from
        // the draft file would vanish on the next launch. Screens go first: a screens file
        // listing a capture no note uses is harmless, while a note whose capture isn't listed
        // would show blank.
        do {
            try persistScreens()
            try persistAnnotations(annotations + [annotation])
        } catch {
            let kept = Set(before.screens.flatMap(\.captures).map(\.id))
            let added = screens.flatMap(\.captures).filter { !kept.contains($0.id) }
            annotations = before.annotations
            screens = before.screens
            for capture in added { captureImages[capture.id] = nil }
            discardAfterWrites(added.map(\.file))
            noteError = "Couldn't save the note. Try again."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        thumbnails[id] = Self.crop(screenImage, around: element.frame)
        notesThisVisit.insert(id)
        if let screenController { noteControllers.setObject(screenController, forKey: id as NSUUID) }
        annotations.append(annotation)
        pruneCaptures()
        fullImages.removeAllObjects()
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

    /// Saves the attachment's images and adds it to the draft.
    ///
    /// A suggested screenshot then sends the report, with everything already in the draft.
    private func saveAttachment(_ attachment: PendingAttachment, note: String) {
        let id = UUID()
        // The app's own screens keep every pixel sharp; photos are stored smaller.
        let isScreen = attachment.kind == .screen
        let files = attachment.images.indices.map { "\(id.uuidString)-\($0 + 1).\(isScreen ? "png" : "jpg")" }
        writeImages(attachment.images, named: files, asPNG: isScreen)
        let annotation = Annotation(
            id: id,
            createdAt: .now,
            note: note,
            kind: attachment.kind,
            element: nil,
            ancestors: [],
            screen: attachment.screen,
            attachments: files
        )
        // An attachment has no capture, so the screens are unchanged. A failed save keeps the
        // note box open with the images and text for another try.
        do {
            try persistAnnotations(annotations + [annotation])
        } catch {
            discardAfterWrites(files)
            self.pending?.isSaving = false
            noteError = "Couldn't save the note. Try again."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        thumbnails[id] = attachment.images.first.flatMap(Self.topSquare(of:))
        annotations.append(annotation)
        pending = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if attachment.sendsReport {
            noteText = ""
            keyboardWait?.cancel()
            isAwaitingKeyboard = false
            send()
        } else {
            endNoting(returningTo: notingReturnMode)
        }
    }

    func delete(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        var remaining = annotations
        remaining.remove(at: index)
        // The draft file goes first, so a failed write leaves the note and its files as they were.
        do {
            try persistAnnotations(remaining)
        } catch {
            showFailure("Couldn't delete the note")
            return
        }
        annotations = remaining
        thumbnails[annotation.id] = nil
        // Other notes on the same screen show this one's outline, so their snapshots are redrawn.
        fullImages.removeAllObjects()
        annotation.attachments.forEach(store.deleteDraftFile(named:))
        pruneCaptures()
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
        guard mode == .tray, annotations.contains(where: { $0.id == annotation.id }) else { return }
        viewerID = annotation.id
        setMode(.viewer)
    }

    func showInViewer(_ id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        viewerID = id
    }

    func closeViewer() {
        viewerID = nil
        fullImages.removeAllObjects()
        setMode(annotations.isEmpty ? trayReturnMode : .tray)
    }

    /// Saves an edited note.
    ///
    /// Returns false only when the change couldn't be saved, so the viewer keeps the edit on screen
    /// and ending the edit, closing or moving on retries.
    @discardableResult
    func updateNote(_ id: UUID, to text: String) -> Bool {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].note != note else {
            return true
        }
        var updated = annotations
        updated[index].note = note
        do {
            try persistAnnotations(updated)
        } catch {
            showFailure("Couldn't save the change to the note")
            return false
        }
        annotations = updated
        return true
    }

    /// One of the item's images at full size: its screen's snapshot with every note on it outlined
    /// and this one standing out, or an attached image.
    ///
    /// Cached with the few around it; the oldest are dropped first.
    func fullImage(for annotation: Annotation, at index: Int) -> UIImage? {
        if let captureID = annotation.captureID { return screenSnapshot(for: annotation, on: captureID) }
        guard annotation.attachments.indices.contains(index) else { return nil }
        let key = "\(annotation.id.uuidString)-\(index)" as NSString
        if let cached = fullImages.object(forKey: key) { return cached }
        let url = store.draftDirectory.appending(path: annotation.attachments[index])
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        fullImages.setObject(image, forKey: key)
        return image
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
        await Self.sentReports(from: store)
    }

    /// Runs off the main actor.
    ///
    /// Add @concurrent when the tools version reaches 6.2.
    nonisolated private static func sentReports(from store: ReportStore) async -> [SentReport] {
        store.sentReports()
    }

    /// The last attempt to hand reports to the Mac, read off the main thread.
    func lastDelivery() async -> Delivery? {
        await Self.lastDelivery(from: store)
    }

    /// Runs off the main actor.
    ///
    /// Add @concurrent when the tools version reaches 6.2.
    nonisolated private static func lastDelivery(from store: ReportStore) async -> Delivery? {
        store.lastDelivery()
    }

    // MARK: - Tray

    func toggleTray() {
        switch mode {
        case .tray:
            setMode(trayReturnMode)
        case .picking, .idle:
            guard !annotations.isEmpty else { return }
            trayReturnMode = mode
            refreshHubAddress()
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
        beginAttachmentNote(
            PendingAttachment(
                kind: .screen,
                images: [capture.image],
                previews: [Self.preview(of: capture.image)],
                screen: capture.screen,
                sendsReport: false
            )
        )
    }

    /// The captured screen has landed in the note box.
    func finishCaptureFlight() {
        captureFlight = nil
    }

    /// Attaches images chosen from Photos, together, as one item with one note.
    ///
    /// The note box opens at once with `previews`, and the full images take their place once
    /// loaded.
    func attachPhotos(previews: [UIImage], count: Int, loading: Task<[UIImage], Never>) {
        guard mode == .attaching, count > 0 else { return }
        beginAttachmentNote(
            PendingAttachment(
                kind: .photo,
                images: previews,
                previews: previews,
                screen: nil,
                sendsReport: false,
                count: count,
                loading: loading
            )
        )
        Task {
            let images = await loading.value
            guard pending?.loading == loading else { return }
            guard !images.isEmpty else {
                logger.error("None of the chosen photos could be loaded")
                cancelNote()
                showFailure(
                    count == 1
                        ? "Couldn't load the photo. Try choosing it again."
                        : "Couldn't load the photos. Try choosing them again."
                )
                return
            }
            if images.count < count { logger.error("Loaded \(images.count) of \(count) chosen photos") }
            // The grid's thumbnails stay as the previews. The system photo picker gives none, and
            // a photo that didn't load leaves them out of step, so then they're made from the photos.
            var shown = pending?.previews ?? []
            if shown.count != images.count {
                shown = []
                for image in images.prefix(3) { shown.append(await Self.preparedPreview(of: image)) }
                guard pending?.loading == loading else { return }
            }
            pending?.images = images
            pending?.previews = shown
            pending?.count = images.count
            pending?.loading = nil
            let missing = count - images.count
            if missing > 0 {
                noteError =
                    "\(missing) of the \(count) photos couldn't be loaded. Add attaches the other \(images.count)."
            }
        }
    }

    // MARK: - Suggested screenshots

    /// Send under a suggested screenshot: write a note, then send it with the rest of the draft.
    func sendSuggestion() {
        guard let suggestion, mode == .idle || mode == .picking else { return }
        suggestionTimer?.cancel()
        self.suggestion = nil
        let attachment = PendingAttachment(
            kind: suggestion.kind,
            images: [suggestion.image],
            previews: [suggestion.preview],
            screen: suggestion.screen,
            sendsReport: true
        )
        beginAttachmentNote(attachment, returningTo: mode)
    }

    func dismissSuggestion() {
        suggestionTimer?.cancel()
        withAnimation(.smooth(duration: 0.3)) { suggestion = nil }
    }

    private func observeScreenshots() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.offerInAppScreenshot() }
            }
        )
        observers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshHubAddress()
                    self?.offerRecentScreenshot()
                    self?.offerUndeliveredReports()
                }
            }
        )
    }

    /// A screenshot was just taken in the app.
    ///
    /// The system's screenshot includes Redline, so the app's own windows are captured instead, at the
    /// same moment, without it.
    private func offerInAppScreenshot() {
        guard window != nil, mode == .idle || mode == .picking else { return }
        let capture = captureScreen()
        rememberInAppCapture(at: .now)
        offer(
            Suggestion(
                image: capture.image,
                preview: Self.cardPreview(of: capture.image),
                kind: .screen,
                screen: capture.screen
            )
        )
    }

    /// The newest screenshot taken in another app in the last 10 minutes, offered once,
    /// only when the app already has Photos access.
    private func offerRecentScreenshot() {
        guard window != nil, PhotoLibrary.canRead else { return }
        let assets = PhotoLibrary.newestScreenshots(limit: 1)
        let candidates = assets.compactMap { asset in
            asset.creationDate.map { ScreenshotSuggestion.Candidate(id: asset.localIdentifier, createdAt: $0) }
        }
        guard
            let pick = ScreenshotSuggestion.candidateToOffer(
                among: candidates,
                now: .now,
                offered: offeredPhotoIDs,
                inAppCaptures: inAppCaptureDates
            ),
            pick.id != loadingPhotoID,
            let asset = assets.first(where: { $0.localIdentifier == pick.id })
        else { return }
        // Noted as offered only once it's shown: one still in iCloud, that doesn't load, or that
        // loads while the debugger is busy is offered again on a later activation.
        loadingPhotoID = pick.id
        Task {
            defer { if loadingPhotoID == pick.id { loadingPhotoID = nil } }
            // Another screenshot may have been offered while this one loaded; it stays.
            guard let image = await PhotoLibrary.image(for: asset, pixels: PhotoLibrary.maxPixels),
                mode == .idle || mode == .picking, suggestion == nil
            else { return }
            let preview = await image.byPreparingThumbnail(ofSize: Self.cardPreviewSize(of: image)) ?? image
            guard mode == .idle || mode == .picking, suggestion == nil else { return }
            markOffered(pick.id)
            offer(Suggestion(image: image, preview: preview, kind: .photo, screen: nil))
        }
    }

    private func offer(_ suggestion: Suggestion) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { self.suggestion = suggestion }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let id = suggestion.id
        // A screenshot nobody acts on steps aside on its own.
        suggestionTimer?.cancel()
        suggestionTimer = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self.suggestion?.id == id else { return }
            dismissSuggestion()
        }
    }

    // MARK: - Handing reports to the Mac

    /// When the app comes back, offers what the Mac hasn't confirmed, such as a report sent from
    /// another network, or one sent before any Mac had set this app up.
    ///
    /// Nothing reaches the network without a report the user sent and a hub's address, so iOS's
    /// local network question is asked at launch only for a report the user is waiting on.
    private func offerUndeliveredReports() {
        let patience = ReportDelivery.patience
        Task(priority: .utility) { [store] in
            _ = await ReportDelivery.deliver(from: store, bundleID: Bundle.main.bundleIdentifier, patience: patience)
        }
    }

    private static let offeredPhotosKey = "RedlineOfferedScreenshots"
    /// The screenshot being loaded to offer, so a second activation meanwhile doesn't load it too.
    @ObservationIgnored private var loadingPhotoID: String?
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
        (UserDefaults.standard.array(forKey: Self.inAppCapturesKey) as? [Double] ?? []).map(
            Date.init(timeIntervalSince1970:)
        )
    }

    private func rememberInAppCapture(at date: Date) {
        let dates =
            (UserDefaults.standard.array(forKey: Self.inAppCapturesKey) as? [Double] ?? []) + [
                date.timeIntervalSince1970
            ]
        UserDefaults.standard.set(Array(dates.suffix(10)), forKey: Self.inAppCapturesKey)
    }

    // MARK: - Where reports go

    private func refreshHubAddress() {
        let address = store.hubAddress()
        if address != hubAddress { hubAddress = address }
    }

    private var destinationKey: String {
        "RedlineDestination|" + (sourceFile ?? Bundle.main.bundleIdentifier ?? "")
    }

    private static let destinationEncoder = JSONEncoder()
    private static let destinationDecoder = JSONDecoder()

    /// The pick saved for this build.
    ///
    /// One that can't be read, or that names an agent the Mac no longer sends reports to, is
    /// forgotten, so the picker opens again.
    private func savedDestination() -> Report.Destination? {
        guard let data = UserDefaults.standard.data(forKey: destinationKey) else { return nil }
        let saved: Report.Destination
        do {
            saved = try Self.destinationDecoder.decode(Report.Destination.self, from: data)
        } catch {
            logger.error("Couldn't read the saved destination: \(error.localizedDescription, privacy: .public)")
            UserDefaults.standard.removeObject(forKey: destinationKey)
            return nil
        }
        guard saved.isForSupportedAgent else {
            logger.notice("Forgot the saved destination: reports no longer go to \(saved.agent, privacy: .public)")
            UserDefaults.standard.removeObject(forKey: destinationKey)
            return nil
        }
        return saved
    }

    /// Opens the picker and asks the Mac for its chats. `thenSend` when opened from Send.
    func openDestinations(thenSend: Bool = false) {
        // An answer to an earlier opening of the picker must not replace this one's.
        chatsRequest?.cancel()
        chatsRequest = nil
        sendsAfterChoosingDestination = thenSend
        // From the note box only a suggested screenshot's Send opens the picker, and its note is
        // already in the draft: Cancel goes to pick mode, which shows that draft and its Send.
        modeBeforeDestinations = mode == .noting || mode == .destination ? .picking : mode
        pickerChoice = destination
        pickerAgent = destination?.agent
        chatList = .loading
        setMode(.destination)
        refreshHubAddress()
        guard let address = hubAddress, let bundleID = Bundle.main.bundleIdentifier else {
            chatList = .unavailable
            return
        }
        let patience = ReportDelivery.patience
        let sourceFile = sourceFile
        chatsRequest = Task {
            let list = await HubLink.requestChats(
                bundleID: bundleID,
                address: address,
                sourceFile: sourceFile,
                patience: patience
            )
            // The hub answered, so iOS has allowed local network access, even if this picker is gone.
            if list != nil { UserDefaults.standard.set(true, forKey: ReportDelivery.hubReachedKey) }
            guard !Task.isCancelled, mode == .destination else { return }
            guard let list else {
                chatList = .unavailable
                return
            }
            chatList = .loaded(list)
            // A saved chat that closed isn't offered; the chat in the build's worktree is.
            if let choice = pickerChoice, let chat = choice.chat,
                !list.chats.contains(where: { $0.id == chat && $0.agent == choice.agent })
            {
                pickerChoice = nil
            }
            // Nor a new chat with an agent the Mac can no longer start one with.
            if let choice = pickerChoice, choice.chat == nil, !list.startsNewChats(choice.agent) {
                pickerChoice = nil
            }
            if pickerChoice == nil, let here = list.chats.first(where: \.isSameWorktree) {
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
        chatsRequest?.cancel()
        chatsRequest = nil
        if let choice = pickerChoice {
            destination = choice
            do {
                UserDefaults.standard.set(try Self.destinationEncoder.encode(choice), forKey: destinationKey)
            } catch {
                logger.error("Couldn't save the destination: \(error.localizedDescription, privacy: .public)")
            }
        } else if case .loaded = chatList {
            // The Mac answered and no longer offers the saved pick: forget it, so the report
            // goes where the Mac routes it instead of to a chat that's gone.
            destination = nil
            UserDefaults.standard.removeObject(forKey: destinationKey)
        }
        let thenSend = sendsAfterChoosingDestination
        sendsAfterChoosingDestination = false
        setMode(modeBeforeDestinations)
        if thenSend { send(pickingFirst: false) }
    }

    func cancelDestinations() {
        chatsRequest?.cancel()
        chatsRequest = nil
        sendsAfterChoosingDestination = false
        setMode(modeBeforeDestinations)
    }

    // MARK: - Send

    /// Sends the draft.
    ///
    /// The first time, the user picks where reports go; after that they go there at once.
    func send(pickingFirst: Bool = true) {
        // One send at a time: a second tap while the first waits is ignored.
        guard !annotations.isEmpty, sending == nil else { return }
        refreshHubAddress()
        if pickingFirst, destination == nil, canPickDestination {
            openDestinations(thenSend: true)
            return
        }
        // The report takes the draft's files with it, so every snapshot must be on disk first.
        // Notes added while waiting add writes of their own; wait for those too.
        sending = Task {
            while !writes.isEmpty {
                let pending = writes
                writes = []
                for write in pending { await write.value }
            }
            sending = nil
            // Synchronous: nothing changes between the last check and the report's snapshot.
            saveReport()
        }
    }

    /// Moves the draft into a report folder at once, so new notes start a fresh draft, then
    /// draws the report's snapshots in the background.
    private func saveReport() {
        guard !annotations.isEmpty else { return }
        let date = Date.now
        let started: (id: String, folder: URL, draft: URL)
        do {
            try store.checkSnapshots(of: annotations, screens: screens)
            started = try store.beginReport(date: date)
        } catch let missing as ReportStore.MissingSnapshot {
            // Redline stays open on the draft, so the note can be deleted and the rest sent.
            let number = (annotations.firstIndex { $0.id == missing.annotationID } ?? 0) + 1
            logger.error("Couldn't send: the snapshot for note \(number) is missing")
            showFailure("Note \(number) lost its snapshot. Delete it, then send.")
            return
        } catch {
            logger.error("Couldn't start the report: \(error.localizedDescription, privacy: .public)")
            showFailure("Couldn't save the report. Your notes are kept.")
            return
        }
        let destination = destination
        let input = ReportBuilder.Input(
            id: started.id,
            date: date,
            app: .current(sourceFile: sourceFile),
            device: .current,
            annotations: annotations,
            screens: screens,
            draft: started.draft,
            folder: started.folder,
            destination: destination
        )
        let count = annotations.count
        annotations = []
        screens = []
        thumbnails = [:]
        fullImages.removeAllObjects()
        captureImages = [:]
        levels = []
        markers = []
        elements = []
        screenImage = nil
        setMode(.idle)

        let store = store
        let logger = logger
        let notes = countPhrase(count, singular: "note", plural: "notes")
        Task(priority: .userInitiated) {
            do {
                let outcome = try await Self.finishAndDeliver(
                    input,
                    folder: started.folder,
                    store: store,
                    logger: logger
                )
                show(Toast(message: ReportDelivery.toast(for: outcome, notes: notes, to: destination?.title)))
            } catch let tooLarge as ReportStore.TooLarge {
                logger.error(
                    "The report is \(tooLarge.bytes) bytes, over the \(ReportStore.largestReport) the Mac takes"
                )
                let megabytes = (tooLarge.bytes + 999_999) / 1_000_000
                restoreDraft(
                    from: input,
                    because: "The report is \(megabytes) MB; the Mac takes up to "
                        + "\(ReportStore.largestReport / 1_000_000) MB. Its notes are back in the draft. "
                        + "Remove some photos, then send."
                )
            } catch {
                logger.error("Couldn't save the report: \(error.localizedDescription, privacy: .public)")
                restoreDraft(from: input)
            }
        }
    }

    /// Puts the notes of a report that couldn't be finished back into the draft, ahead of any made
    /// since, so they can be sent again, and says why with `message`.
    private func restoreDraft(
        from input: ReportBuilder.Input,
        because message: String = "Couldn't save the report. Its notes are back in the draft."
    ) {
        let before = screens
        do {
            try store.reclaimDraftFiles(from: input.folder)
        } catch {
            logger.error("Couldn't take back the report's snapshots: \(error.localizedDescription, privacy: .public)")
            showFailure("Couldn't save the report or bring its notes back")
            return
        }
        screens = input.screens + screens
        let restored = input.annotations + annotations
        do {
            // Screens first: a screens file listing a capture no note uses is harmless, while a
            // note whose capture isn't listed would show blank.
            try persistScreens()
            try persistAnnotations(restored)
        } catch {
            screens = before
            showFailure("Couldn't save the report or bring its notes back")
            return
        }
        annotations = restored
        store.discardReport(input.folder)
        refreshMarkers()
        showFailure(message)
    }

    /// Draws the report's snapshots, writes it, then hands every report the Mac hasn't confirmed to
    /// its hub.
    ///
    /// Returns how that went. Runs off the main actor. Add @concurrent when the tools version
    /// reaches 6.2.
    nonisolated private static func finishAndDeliver(
        _ input: ReportBuilder.Input,
        folder: URL,
        store: ReportStore,
        logger: Logger
    ) async throws -> HubLink.Outcome? {
        let report = try ReportBuilder.build(input)
        try store.checkSize(of: report, in: folder)
        try store.finishReport(report, in: folder)
        logger.notice("Report saved at \(folder.path(percentEncoded: false), privacy: .public)")
        return await ReportDelivery.deliver(
            from: store,
            bundleID: Bundle.main.bundleIdentifier,
            patience: ReportDelivery.patience
        )
    }

    // MARK: - One snapshot per screen state

    /// Files the screen as just read under its screen (see `CaptureMerge.place`): one snapshot per
    /// state of the screen.
    ///
    /// Returns the capture the new note belongs to.
    private func fileCapture(_ image: UIImage, for element: ElementSnapshot) -> UUID {
        let capture = Capture(
            id: UUID(),
            file: "capture-\(UUID().uuidString).png",
            size: readSize,
            scroll: scrollState,
            elements: elements,
            group: 0
        )
        let filing = CaptureMerge.place(
            capture,
            image: image.cgImage,
            element: element,
            screen: screen,
            screens: &screens,
            annotations: &annotations
        ) { captureImage($0)?.cgImage }
        if filing.isNewCapture { keep(image, for: capture) }
        for id in filing.movedNotes { thumbnails[id] = nil }
        return filing.captureID
    }

    private func keep(_ image: UIImage, for capture: Capture) {
        captureImages[capture.id] = image
        writeImages([image], named: [capture.file], asPNG: true)
    }

    /// A capture's image, loaded from the draft the first time and kept while it's in use.
    private func captureImage(_ capture: Capture) -> UIImage? {
        if let cached = captureImages[capture.id] { return cached }
        guard
            let image = UIImage(
                contentsOfFile: store.draftDirectory.appending(path: capture.file).path(percentEncoded: false)
            )
        else { return nil }
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
    ///
    /// Called once the draft no longer refers to them.
    private func pruneCaptures() {
        let used = Set(annotations.compactMap(\.captureID))
        let before = screens
        for index in screens.indices.reversed() {
            for capture in screens[index].captures where !used.contains(capture.id) {
                store.deleteDraftFile(named: capture.file)
                captureImages[capture.id] = nil
            }
            screens[index].captures.removeAll { !used.contains($0.id) }
            if screens[index].captures.isEmpty { screens.remove(at: index) }
        }
        guard screens != before else { return }
        do {
            try persistScreens()
        } catch {
            // Logged. The screens file still lists the dropped captures, which no note uses.
        }
    }

    /// The capture a note was made on, with every note of its screen that's in view outlined and
    /// numbered, the note itself standing out.
    ///
    /// Cached like `fullImage(for:at:)`.
    private func screenSnapshot(for annotation: Annotation, on captureID: UUID) -> UIImage? {
        let key = "\(annotation.id.uuidString)-screen" as NSString
        if let cached = fullImages.object(forKey: key) { return cached }
        guard let (record, capture) = capture(withID: captureID), let image = captureImage(capture),
            let plan = ScreenComposition.plan(for: [capture])
        else { return nil }
        let group = record.captures.filter { $0.group == capture.group }
        let band = ScreenComposition.band(for: group)
        let outlines = annotations.enumerated().compactMap { index, other -> ReportRenderer.Outline? in
            guard let otherCapture = other.captureID.flatMap({ id in group.first { $0.id == id } }),
                let frame = other.element?.frame,
                let rect = ScreenComposition.position(of: frame, from: otherCapture, on: capture, band: band)
            else { return nil }
            return ReportRenderer.Outline(
                number: index + 1,
                rect: rect,
                style: other.id == annotation.id ? .current : .quiet
            )
        }
        let snapshot = ReportRenderer.render(plan, captures: [capture.id: image], outlines: outlines, scale: 2)
        fullImages.setObject(snapshot, forKey: key)
        return snapshot
    }

    /// A close crop of the picked element from the screen as last read, for the note card
    /// when the element itself is hidden behind the keyboard or the card.
    func selectedElementPreview() -> UIImage? {
        guard let frame = selected?.frame, let image = screenImage else { return nil }
        return Self.crop(image, around: frame)
    }

    // MARK: - Thumbnails and previews

    /// The suggestion card's width in pixels: 96 points at 3x.
    private static let cardPreviewWidth: CGFloat = 288
    /// The note box's image slot's height in pixels: 56 points at 3x.
    private static let notePreviewHeight: CGFloat = 168
    /// The largest a thumbnail is shown, in pixels: 52 points at 3x.
    private static let thumbnailSide: CGFloat = 156

    private static func cardPreviewSize(of image: UIImage) -> CGSize {
        CGSize(
            width: cardPreviewWidth,
            height: (cardPreviewWidth * image.size.height / max(image.size.width, 1)).rounded()
        )
    }

    private static func notePreviewSize(of image: UIImage) -> CGSize {
        CGSize(
            width: (notePreviewHeight * image.size.width / max(image.size.height, 1)).rounded(),
            height: notePreviewHeight
        )
    }

    /// The suggestion card's preview of an image.
    private static func cardPreview(of image: UIImage) -> UIImage {
        image.preparingThumbnail(of: cardPreviewSize(of: image)) ?? image
    }

    /// The note box's thumbnail of an image.
    private static func preview(of image: UIImage) -> UIImage {
        image.preparingThumbnail(of: notePreviewSize(of: image)) ?? image
    }

    /// The note box's thumbnail of an image, made off the main thread.
    private static func preparedPreview(of image: UIImage) async -> UIImage {
        await image.byPreparingThumbnail(ofSize: notePreviewSize(of: image)) ?? image
    }

    /// A bitmap of its own, no bigger than a thumbnail is shown.
    ///
    /// A cropped image keeps the whole image it was cut from alive; this one doesn't.
    private static func thumbnailBitmap(_ image: CGImage) -> UIImage? {
        let scale = min(thumbnailSide / CGFloat(max(image.width, 1)), thumbnailSide / CGFloat(max(image.height, 1)), 1)
        let size = CGSize(
            width: (CGFloat(image.width) * scale).rounded(),
            height: (CGFloat(image.height) * scale).rounded()
        )
        return UIImage(cgImage: image).preparingThumbnail(of: size)
    }

    /// A square crop for a thumbnail.
    ///
    /// A wide element keeps its leading end and a tall one its top, where the icon and title
    /// usually are; the middle of a row is often empty. `frame` is in the points of the screen
    /// the image was taken of, which may have been a different size or orientation from the
    /// screen now.
    private static func crop(_ image: UIImage, around frame: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let scale = AppWindows.screenshotScale
        var area = frame.insetBy(dx: -12, dy: -12)
        let side = min(area.width, area.height)
        area.size = CGSize(width: side, height: side)
        let crop = CGRect(
            x: area.minX * scale,
            y: area.minY * scale,
            width: area.width * scale,
            height: area.height * scale
        )
        .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !crop.isEmpty, let cropped = cgImage.cropping(to: crop) else { return nil }
        return thumbnailBitmap(cropped)
    }

    /// The top of an attached image, square, where a screen's title usually is.
    private static func topSquare(of image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let side = min(cgImage.width, cgImage.height)
        let crop = CGRect(x: (cgImage.width - side) / 2, y: 0, width: side, height: side)
        return cgImage.cropping(to: crop).flatMap(thumbnailBitmap)
    }

    /// A thumbnail of the item for the notes list: a close crop around its element, or the top
    /// of its first image.
    ///
    /// Cached for the life of the draft.
    func thumbnail(for annotation: Annotation) -> UIImage? {
        if let cached = thumbnails[annotation.id] { return cached }
        if let captureID = annotation.captureID, let element = annotation.element {
            guard let (_, capture) = capture(withID: captureID), let image = captureImage(capture),
                let thumbnail = Self.crop(image, around: element.frame)
            else { return nil }
            thumbnails[annotation.id] = thumbnail
            return thumbnail
        }
        guard let first = annotation.attachments.first,
            let image = UIImage(contentsOfFile: store.draftDirectory.appending(path: first).path(percentEncoded: false))
        else { return nil }
        let thumbnail = annotation.element.map { Self.crop(image, around: $0.frame) } ?? Self.topSquare(of: image)
        guard let thumbnail else { return nil }
        thumbnails[annotation.id] = thumbnail
        return thumbnail
    }

    // MARK: - Note card placement

    /// The keyboard's top edge for placing the note card.
    ///
    /// Until the keyboard reports its frame, the last keyboard height stands in for it, so the card
    /// opens where it will end up instead of jumping when the keyboard arrives.
    var noteKeyboardTop: CGFloat {
        isAwaitingKeyboard ? screenSize.height - expectedKeyboardHeight : keyboardTop
    }

    /// The note card's top edge.
    func noteCardTop(height: CGFloat, reservedHeight: CGFloat) -> CGFloat {
        NoteCardPlacement.top(
            // After a rotation the picked frame points at the wrong place; the card shows
            // a crop of the element instead.
            element: screenReadIsCurrent ? selected?.frame : nil,
            height: height,
            reservedHeight: reservedHeight,
            top: safeAreaTop,
            bottom: noteCardBottom
        )
    }

    /// The tallest the note card can be and still fit whole above the keyboard.
    var noteCardMaxHeight: CGFloat {
        NoteCardPlacement.maxHeight(top: safeAreaTop, bottom: noteCardBottom)
    }

    /// The lowest the note card's bottom may go: the keyboard, or the home indicator without one.
    private var noteCardBottom: CGFloat {
        min(noteKeyboardTop, screenSize.height - safeAreaInsets.bottom)
    }

    private static let keyboardHeightKey = "RedlineKeyboardHeight"

    /// The last keyboard height seen, or a typical iPhone keyboard with the
    /// suggestion bar before any keyboard has shown.
    private var expectedKeyboardHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: Self.keyboardHeightKey)
        return saved > 0 ? saved : screenSize.height * 0.385
    }

    // MARK: - Floating button

    /// Follows the finger during a drag, kept on screen.
    ///
    /// No snapping yet.
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
    ///
    /// Frames come from SwiftUI's global space, which equals this window's coordinates only
    /// because the overlay window fills the screen and the hosting controller ignores safe areas.
    func setTouchableFrame(_ frame: CGRect?, for area: TouchableArea) {
        window?.touchableRects[area] = frame
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
        } else if let saved = UserDefaults.standard.array(forKey: Self.buttonPositionKey) as? [Double], saved.count == 2
        {
            buttonCenter = FloatingButtonPlacement.center(
                fromFraction: CGPoint(x: saved[0], y: saved[1]),
                within: buttonArea
            )
        } else {
            buttonCenter = FloatingButtonPlacement.defaultCenter(within: buttonArea)
        }
    }

    // MARK: - Feedback

    /// A tap in pick mode that found nothing: the app didn't respond because Redline has the
    /// screen.
    ///
    /// Says so, rather than leaving the tester to think the app is broken.
    private func nudge() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        withAnimation(.linear(duration: 0.4)) { nudges += 1 }
        withAnimation(.smooth(duration: 0.25)) { hint = "Annotate mode" }
        UIAccessibility.post(notification: .announcement, argument: "Annotate mode. Close it to use the app.")
        hintTimer?.cancel()
        hintTimer = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { hint = nil }
        }
    }

    private func show(_ message: Toast) {
        toast = message
        toastTimer?.cancel()
        toastTimer = Task {
            try? await Task.sleep(for: .seconds(message.isError ? 4 : 2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func showFailure(_ message: String) {
        show(Toast(message: message, isError: true))
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: - Display

    /// The display's corner radius, read through a private key; square corners when it can't be
    /// read.
    ///
    /// Debug builds only, like the rest of the kit.
    private static func displayCornerRadius(of screen: UIScreen) -> CGFloat {
        let key = "_displayCornerRadius"
        guard screen.responds(to: NSSelectorFromString(key)) else { return 0 }
        return (screen.value(forKey: key) as? CGFloat) ?? 0
    }

    // MARK: - Mode

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

    // MARK: - Noting

    private func beginNoting() {
        noteError = nil
        isAwaitingKeyboard = keyboardTop == .infinity
        setMode(.noting)
        // A hardware keyboard never shows the on-screen one; stop waiting for it. Only this card's
        // wait may end it, not one left from a card closed moments ago.
        keyboardWait?.cancel()
        keyboardWait = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled, isAwaitingKeyboard else { return }
            withAnimation(.smooth(duration: 0.25)) { isAwaitingKeyboard = false }
        }
    }

    private func endNoting(returningTo next: Mode) {
        noteText = ""
        keyboardWait?.cancel()
        keyboardWait = nil
        isAwaitingKeyboard = false
        noteError = nil
        setMode(next)
    }

    private func beginAttachmentNote(_ attachment: PendingAttachment, returningTo next: Mode = .picking) {
        pending = attachment
        levels = []
        noteText = ""
        notingReturnMode = next
        beginNoting()
    }

    // MARK: - Saving the draft

    /// Encodes and writes images off the main thread, so closing the note box never waits on a
    /// large PNG or JPEG.
    ///
    /// The list and viewer read them back only after this finishes.
    private func writeImages(_ images: [UIImage], named names: [String], asPNG: Bool) {
        let store = store
        let logger = logger
        writes.append(
            Task(priority: .userInitiated) {
                await Self.write(images, named: names, asPNG: asPNG, store: store, logger: logger)
            }
        )
    }

    /// Runs off the main actor.
    ///
    /// Add @concurrent when the tools version reaches 6.2.
    nonisolated private static func write(
        _ images: [UIImage],
        named names: [String],
        asPNG: Bool,
        store: ReportStore,
        logger: Logger
    ) async {
        for (image, name) in zip(images, names) {
            guard let data = asPNG ? image.pngData() : image.jpegData(compressionQuality: 0.85) else {
                logger.error("Couldn't encode snapshot \(name, privacy: .public)")
                continue
            }
            do {
                try store.saveDraftFile(data, named: name)
            } catch {
                logger.error("Couldn't save a snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Saves `updated` as the draft's notes.
    ///
    /// Callers change `annotations` only once this succeeds, so the notes on screen always match
    /// what the next launch loads.
    private func persistAnnotations(_ updated: [Annotation]) throws {
        do {
            try store.saveDraft(updated)
        } catch {
            logger.error("Couldn't save the draft's notes: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The screens hold every capture's elements, so they're written only when they change.
    private func persistScreens() throws {
        do {
            try store.saveScreens(screens)
        } catch {
            logger.error("Couldn't save the draft's screens: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Deletes the images of a note that couldn't be saved, once they're written.
    private func discardAfterWrites(_ files: [String]) {
        guard !files.isEmpty else { return }
        let pending = writes
        let store = store
        Task {
            for write in pending { await write.value }
            files.forEach(store.deleteDraftFile(named:))
        }
    }

    // MARK: - Reading the screen

    /// The app's screen as it is now, without Redline, and the screen's name.
    private func captureScreen() -> (image: UIImage, screen: ScreenInfo) {
        let windows = appWindows()
        let bounds = window?.bounds ?? .zero
        let roots = AccessibilityTree.visibleRoots(in: windows)
        let elements = AccessibilityTree.elements(under: roots, screenBounds: bounds)
        let screen = AccessibilityTree.screen(
            of: windows.first(where: \.isKeyWindow) ?? windows.last,
            elements: elements
        )
        return (AppWindows.screenshot(of: windows, bounds: bounds), screen)
    }

    /// Reads every element's position, the screen's name and an image of the screen, all at the same moment.
    private func readScreen() {
        guard let window else { return }
        let appWindows = self.appWindows()
        // Found once and shared: finding them walks a presented sheet's tree.
        let roots = AccessibilityTree.visibleRoots(in: appWindows)
        let screenWindow = appWindows.first(where: \.isKeyWindow) ?? appWindows.last
        let previousController = screenController
        let previousScreen = screen
        elements = AccessibilityTree.elements(under: roots, screenBounds: window.bounds)
        screen = AccessibilityTree.screen(of: screenWindow, elements: elements)
        screenController = AccessibilityTree.topController(of: screenWindow)
        // The app can still move on by itself, after a timer or a network response. Notes
        // made before that belong to the screen it left, so a new visit starts.
        if screenController !== previousController || screen != previousScreen {
            notesThisVisit = []
        }
        screenImage = AppWindows.screenshot(of: appWindows, bounds: window.bounds)
        scrollState = AppWindows.mainScrollState(under: roots, screenBounds: window.bounds)
        readSize = window.bounds.size
        refreshMarkers()
    }

    /// Markers go on notes made on this screen.
    ///
    /// Notes added since pick mode opened count while the screen read is the same one they
    /// were made on. An earlier note counts only when it was taken on the very view controller
    /// showing now, with the same title: two SwiftUI destinations can share a title and a
    /// hosting controller type, and one untitled controller can show several screens in turn.
    /// Notes from an earlier launch get no marker, since nothing ties them to a screen open now.
    private func refreshMarkers() {
        let found = annotations.enumerated().compactMap { index, annotation -> Marker? in
            let isSameController =
                screenController.map { noteControllers.object(forKey: annotation.id as NSUUID) === $0 } ?? false
            let sameScreen =
                notesThisVisit.contains(annotation.id)
                || (isSameController && screen.title != nil && annotation.screen == screen)
            guard let element = annotation.element, sameScreen,
                let match = ElementSelection.match(element, in: elements)
            else { return nil }
            return Marker(id: annotation.id, number: index + 1, frame: match.frame)
        }
        if found != markers { markers = found }
    }

    /// The app's own visible windows, bottom to top, without Redline's.
    private func appWindows() -> [UIWindow] {
        AppWindows.all(in: window?.windowScene)
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) {
                [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                MainActor.assumeIsolated { self?.updateKeyboard(frame, duration: duration) }
            }
        )
        observers.append(
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) {
                [weak self] note in
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                MainActor.assumeIsolated { self?.updateKeyboard(nil, duration: duration) }
            }
        )
    }

    /// Moves the note card with the keyboard, on the keyboard's own timing curve.
    private func updateKeyboard(_ frame: CGRect?, duration: Double) {
        let visible = frame.map { $0.minY < screenSize.height && $0.height > 0 } ?? false
        // The keyboard reports the same frame again and again; publish and save only changes.
        withAnimation(.timingCurve(0.38, 0.7, 0.125, 1, duration: max(duration, 0.2))) {
            if visible, let frame {
                if keyboardTop != frame.minY { keyboardTop = frame.minY }
                if isAwaitingKeyboard { isAwaitingKeyboard = false }
                let height = Double(screenSize.height - frame.minY)
                if UserDefaults.standard.double(forKey: Self.keyboardHeightKey) != height {
                    UserDefaults.standard.set(height, forKey: Self.keyboardHeightKey)
                }
            } else if keyboardTop != .infinity {
                keyboardTop = .infinity
            }
        }
    }
}
#endif
