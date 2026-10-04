#if REDLINE && canImport(UIKit)
import SwiftUI
import UIKit

/// The saved notes, full screen: each note's screenshot with its note underneath.
/// Every image is a page, so a note with several attached images pages through them.
/// Swipe or use the strip to move between notes. A tap on the screenshot hides or
/// shows the details, and zooming in hides them. Modeled on Tiny Tally's photo viewer.
struct NoteViewer: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One image of one note.
    private struct Page: Identifiable {
        let annotation: Annotation
        let number: Int
        let index: Int
        var id: String { "\(annotation.id.uuidString)-\(index)" }
    }

    /// The page the pager has settled on, kept apart from `session.viewerID` so the two can lead each other.
    @State private var shownID: String?
    @State private var showsDetails = true
    @State private var isZoomed = false
    @State private var draft = ""
    /// The note the draft belongs to, so moving to another note saves it against the right one.
    @State private var draftOwner: UUID?
    @State private var isConfirmingDelete = false
    /// The details panel's height, which sets where the screenshot ends. Kept from before
    /// a zoom, so the screenshot never resizes under the finger while the details are hidden.
    @State private var detailsHeight: CGFloat = 0
    @FocusState private var isEditingNote: Bool

    private var annotations: [Annotation] { session.annotations }
    private var currentIndex: Int? { annotations.firstIndex { $0.id == session.viewerID } }
    private var current: Annotation? { currentIndex.map { annotations[$0] } }
    private var pages: [Page] {
        annotations.enumerated().flatMap { number, annotation in
            (0..<annotation.imageCount).map { Page(annotation: annotation, number: number + 1, index: $0) }
        }
    }
    /// The page showing, or the first page of the current note before the pager settles.
    private var currentPage: Page? {
        let pages = pages
        return pages.first { $0.id == shownID && $0.annotation.id == session.viewerID }
            ?? pages.first { $0.annotation.id == session.viewerID }
    }
    private var detailsVisible: Bool { showsDetails && !isZoomed }
    private var size: CGSize { session.screenSize }
    /// The details panel rises with the keyboard while a note is edited.
    private var panelBottom: CGFloat { min(session.keyboardTop, size.height - session.safeAreaInsets.bottom) - 8 }
    /// The screenshot sits between the top bar and the details panel, so the outlined
    /// element is never under the panel and the picture never reads as the live app.
    private var imageTop: CGFloat { session.safeAreaTop + 56 }
    /// While a note is edited the screenshot shrinks to the space above the panel,
    /// so the outlined element stays in view next to what is being written about it.
    private var imageHeight: CGFloat {
        let reserve = detailsHeight == 0 ? 200 : detailsHeight
        return max(panelBottom - reserve - 12 - imageTop, 120)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            pager
                .frame(height: imageHeight)
                .padding(.top, imageTop)
            if detailsVisible {
                topBar
                    .transition(.opacity)
                details
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, size.height - panelBottom)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        // The panel follows the keyboard itself; SwiftUI must not also push the whole viewer up.
        .ignoresSafeArea()
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25), value: detailsVisible)
        .onChange(of: session.viewerID, initial: true) { _, id in
            guard id != draftOwner else { return }
            // An edit that couldn't be saved keeps its note on screen, so it isn't lost.
            if let owner = draftOwner, !saveDraft() {
                session.showInViewer(owner)
                return
            }
            draftOwner = id
            draft = current?.note ?? ""
            isZoomed = false
        }
        .onDisappear { saveDraft() }
    }

    // MARK: - Pager

    private var pager: some View {
        let pages = pages
        let shownPosition = pages.firstIndex { $0.id == currentPage?.id } ?? 0
        return ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { position, page in
                        self.page(page, isNear: abs(position - shownPosition) <= 1)
                            .padding(.horizontal, 16)
                            .frame(width: size.width, height: imageHeight)
                            .id(page.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $shownID)
            .scrollDisabled(isZoomed)
            .frame(width: size.width, height: imageHeight)
            // A scroll position binding is not honored on first layout, so the first jump is made explicitly.
            .onAppear {
                shownID = currentPage?.id
                if let id = shownID { scroller.scrollTo(id, anchor: .center) }
            }
            .onChange(of: session.viewerID) { _, id in
                // Another note was chosen from the strip, or the one showing was deleted.
                guard let id, self.pages.first(where: { $0.id == shownID })?.annotation.id != id,
                      let first = self.pages.first(where: { $0.annotation.id == id })
                else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { scroller.scrollTo(first.id, anchor: .center) }
            }
            .onChange(of: shownID) { _, id in
                if let page = self.pages.first(where: { $0.id == id }), page.annotation.id != session.viewerID {
                    session.showInViewer(page.annotation.id)
                }
            }
        }
    }

    /// Only the page showing and its neighbors hold a full-size image.
    @ViewBuilder
    private func page(_ page: Page, isNear: Bool) -> some View {
        let number = page.number
        if isNear, let image = session.fullImage(for: page.annotation, at: page.index) {
            // The zoom view is its own accessibility element, with Zoom in and Zoom out actions.
            ZoomableScreenshot(
                image: image,
                label: page.annotation.imageCount > 1
                    ? "Image \(page.index + 1) of \(page.annotation.imageCount) for note \(number)"
                    : "Screenshot for note \(number)",
                zoomChanged: { isZoomed = $0 },
                tapped: { if isEditingNote { isEditingNote = false } else { showsDetails.toggle() } }
            )
        } else {
            Color.clear
        }
    }

    // MARK: - Details

    private var topBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Mono.text)
                    .frame(width: 36, height: 36)
                    .background(Mono.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Mono.hairline, lineWidth: 1))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            Spacer()
            if annotations.count > 1, let index = currentIndex {
                Text("\(index + 1) of \(annotations.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Mono.text)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Mono.surface, in: Capsule(style: .continuous))
                    .overlay(Capsule(style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
            }
            Spacer()
            // Balances the close button so the position stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, session.safeAreaTop + 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let current, let index = currentIndex {
                HStack(spacing: 12) {
                    NumberBadge(number: index + 1, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(current.element.map { $0.label ?? $0.identifier ?? $0.role } ?? current.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Mono.text)
                        Text(subtitle(for: current))
                            .font(.caption)
                            .foregroundStyle(Mono.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button { isConfirmingDelete = true } label: {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(Color.red)
                            .frame(width: 36, height: 36)
                            .background(Mono.fill, in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete note \(index + 1)")
                    .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        Button("Delete note", role: .destructive) {
                            isEditingNote = false
                            session.delete(current)
                        }
                    }
                }

                // Typed right here; the panel rises with the keyboard and the screenshot fits above it.
                TextField("What's wrong?", text: $draft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Mono.text)
                    .tint(Color.white)
                    .lineLimit(1...4)
                    .focused($isEditingNote)
                    .onChange(of: draft) { _, text in
                        // Return ends the note; a vertical field would otherwise add a line.
                        if text.contains("\n") {
                            draft = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                            isEditingNote = false
                        }
                    }
                    .onChange(of: isEditingNote) { _, isEditing in if !isEditing { saveDraft() } }
                    .padding(12)
                    .background(Mono.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if annotations.count > 1 { strip }
            }
        }
        .padding(16)
        .frame(width: min(size.width - 24, 420))
        .background(Mono.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
    }

    /// What the note is, and which of its images is showing when it has several.
    private func subtitle(for annotation: Annotation) -> String {
        guard annotation.imageCount > 1, let page = currentPage else { return annotation.subtitle }
        return "\(annotation.subtitle) · \(page.index + 1) of \(annotation.imageCount)"
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
                        Button { session.showInViewer(annotation.id) } label: {
                            stripThumbnail(for: annotation)
                                .padding(3)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 2)
                                        .opacity(annotation.id == session.viewerID ? 1 : 0)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Note \(index + 1) of \(annotations.count)")
                        .accessibilityAddTraits(annotation.id == session.viewerID ? .isSelected : [])
                        .id(annotation.id)
                    }
                }
            }
            .onChange(of: session.viewerID) { _, id in
                if let id { withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private func stripThumbnail(for annotation: Annotation) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let image = session.thumbnail(for: annotation) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(shape)
        } else {
            shape.fill(Mono.fill).frame(width: 44, height: 44)
        }
    }

    /// Returns false when the edit couldn't be saved; the session has already said so.
    @discardableResult
    private func saveDraft() -> Bool {
        guard let owner = draftOwner else { return true }
        return session.updateNote(owner, to: draft)
    }

    /// Stays open when the edit couldn't be saved, so it can be retried instead of lost.
    private func close() {
        guard saveDraft() else { return }
        draftOwner = nil
        session.closeViewer()
    }
}

/// A screenshot that can be pinched, double-tapped and dragged, built on the system
/// scroll view so zooming, bouncing and handing a sideways swipe to the pager behave
/// the way Photos does. VoiceOver zooms through the element's actions. Modeled on
/// Tiny Tally's zoomable photo.
struct ZoomableScreenshot: UIViewRepresentable {
    let image: UIImage
    let label: String
    /// Reports whether the screenshot is zoomed in, so the details can step out of the way.
    let zoomChanged: (Bool) -> Void
    let tapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(zoomChanged: zoomChanged, tapped: tapped) }

    func makeUIView(context: Context) -> ZoomView {
        let view = ZoomView()
        view.delegate = context.coordinator
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped))
        single.require(toFail: double)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)
        view.show(image)
        view.accessibilityLabel = label
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        context.coordinator.zoomChanged = zoomChanged
        context.coordinator.tapped = tapped
        view.accessibilityLabel = label
        if view.photo.image !== image { view.show(image) }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var zoomChanged: (Bool) -> Void
        var tapped: () -> Void
        private var wasZoomed = false

        init(zoomChanged: @escaping (Bool) -> Void, tapped: @escaping () -> Void) {
            self.zoomChanged = zoomChanged
            self.tapped = tapped
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomView)?.photo }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = scrollView as? ZoomView else { return }
            view.centerPhoto()
            let isZoomed = view.isZoomedIn
            guard isZoomed != wasZoomed else { return }
            wasZoomed = isZoomed
            zoomChanged(isZoomed)
        }

        @objc func singleTapped() { tapped() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ZoomView else { return }
            // Zoom into the point that was tapped rather than the middle.
            view.toggleZoom(at: gesture.location(in: view.photo))
        }
    }

    final class ZoomView: UIScrollView {
        static let doubleTapScale: CGFloat = 2.5
        let photo = UIImageView()
        private var laidOutSize = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            photo.contentMode = .scaleAspectFit
            photo.clipsToBounds = true
            photo.layer.cornerCurve = .continuous
            photo.layer.cornerRadius = 14
            photo.layer.borderWidth = 1
            photo.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
            addSubview(photo)
            minimumZoomScale = 1
            maximumZoomScale = 5
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            bouncesZoom = true
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            backgroundColor = .clear
            isAccessibilityElement = true
            accessibilityTraits = .image
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        var isZoomedIn: Bool { zoomScale > minimumZoomScale + 0.01 }

        func toggleZoom(at point: CGPoint) {
            if isZoomedIn {
                setZoomScale(minimumZoomScale, animated: true)
            } else {
                let scale = Self.doubleTapScale
                let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }

        override var accessibilityValue: String? {
            get { isZoomedIn ? "Zoomed in" : nil }
            set {}
        }

        /// The double-tap zoom gesture is out of reach under VoiceOver, so the same zoom is an action.
        override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
            get {
                let name = isZoomedIn ? "Zoom out" : "Zoom in"
                return [UIAccessibilityCustomAction(name: name) { [weak self] _ in
                    guard let self else { return false }
                    toggleZoom(at: CGPoint(x: photo.bounds.midX, y: photo.bounds.midY))
                    return true
                }]
            }
            set {}
        }

        func show(_ image: UIImage) {
            photo.image = image
            laidOutSize = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0, let image = photo.image else {
                // The system nudges a scroll view for the keyboard and doesn't always put it back.
                // A screenshot that isn't zoomed belongs in the middle of the screen.
                if !isZoomedIn, !isDragging, !isZooming { settleInCenter() }
                return
            }
            laidOutSize = bounds.size
            zoomScale = minimumZoomScale
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            photo.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit, height: image.size.height * fit))
            contentSize = photo.frame.size
            centerPhoto()
        }

        private func settleInCenter() {
            centerPhoto()
            let resting = CGPoint(x: -contentInset.left, y: -contentInset.top)
            if contentOffset != resting { contentOffset = resting }
        }

        /// Keeps a screenshot smaller than the screen in the middle instead of pinned to the top left.
        func centerPhoto() {
            let horizontal = max((bounds.width - contentSize.width) / 2, 0)
            let vertical = max((bounds.height - contentSize.height) / 2, 0)
            contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        }
    }
}
#endif
