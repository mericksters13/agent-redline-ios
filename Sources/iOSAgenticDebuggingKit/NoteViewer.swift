#if AGENTIC_DEBUGGING && canImport(UIKit)
import SwiftUI
import UIKit

/// The saved notes, full screen: each note's screenshot with its note underneath.
/// Swipe or use the strip to move between notes. A tap on the screenshot hides or
/// shows the details, and zooming in hides them. Modeled on Tiny Tally's photo viewer.
struct NoteViewer: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page the pager has settled on, kept apart from `session.viewerID` so the two can lead each other.
    @State private var shownID: UUID?
    @State private var showsDetails = true
    @State private var isZoomed = false
    @State private var draft = ""
    /// The note the draft belongs to, so moving to another note saves it against the right one.
    @State private var draftOwner: UUID?
    @State private var isConfirmingDelete = false
    @FocusState private var isEditingNote: Bool

    private var annotations: [Annotation] { session.annotations }
    private var currentIndex: Int? { annotations.firstIndex { $0.id == session.viewerID } }
    private var current: Annotation? { currentIndex.map { annotations[$0] } }
    private var detailsVisible: Bool { showsDetails && !isZoomed }
    private var size: CGSize { session.screenSize }
    /// The details panel rises with the keyboard while a note is edited.
    private var panelBottom: CGFloat { min(session.keyboardTop, size.height - session.safeAreaInsets.bottom) - 8 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            pager
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
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25), value: detailsVisible)
        .onChange(of: session.viewerID, initial: true) { _, _ in
            saveDraft()
            draftOwner = session.viewerID
            draft = current?.note ?? ""
            isZoomed = false
        }
        .onDisappear(perform: saveDraft)
    }

    // MARK: - Pager

    private var pager: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
                        page(for: annotation, number: index + 1, isNear: abs(index - (currentIndex ?? 0)) <= 1)
                            .frame(width: size.width, height: size.height)
                            .id(annotation.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $shownID)
            .scrollDisabled(isZoomed)
            .frame(width: size.width, height: size.height)
            // A scroll position binding is not honored on first layout, so the first jump is made explicitly.
            .onAppear {
                shownID = session.viewerID
                if let id = session.viewerID { scroller.scrollTo(id, anchor: .center) }
            }
            .onChange(of: session.viewerID) { _, id in
                guard let id, shownID != id else { return }
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { scroller.scrollTo(id, anchor: .center) }
            }
            .onChange(of: shownID) { _, id in
                if let id, id != session.viewerID { session.showInViewer(id) }
            }
        }
    }

    /// Only the note showing and its neighbors hold a full-size screenshot.
    @ViewBuilder
    private func page(for annotation: Annotation, number: Int, isNear: Bool) -> some View {
        if isNear, let image = session.fullScreenshot(for: annotation) {
            ZoomableScreenshot(
                image: image,
                zoomChanged: { isZoomed = $0 },
                tapped: { if isEditingNote { isEditingNote = false } else { showsDetails.toggle() } }
            )
            .accessibilityElement()
            .accessibilityLabel("Screenshot for note \(number)")
            .accessibilityValue(isZoomed ? "Zoomed in" : "")
            .accessibilityHint("Double-tap with two fingers to zoom")
            .accessibilityAddTraits(.isImage)
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
                        Text(current.element.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Mono.text)
                        Text(current.screen.title.map { "On \($0)" } ?? current.element.role)
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
                        Button("Delete note", role: .destructive) { session.delete(current) }
                    }
                }

                // Typed right here; the panel rises with the keyboard and the screenshot stays put.
                TextField("What's wrong?", text: $draft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(Mono.text)
                    .tint(Color.white)
                    .lineLimit(1...4)
                    .focused($isEditingNote)
                    .submitLabel(.done)
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

    private func saveDraft() {
        guard let owner = draftOwner else { return }
        session.updateNote(owner, to: draft)
    }

    private func close() {
        saveDraft()
        draftOwner = nil
        session.closeViewer()
    }
}

/// A screenshot that can be pinched, double-tapped and dragged, built on the system
/// scroll view so zooming, bouncing and handing a sideways swipe to the pager behave
/// the way Photos does. Modeled on Tiny Tally's zoomable photo.
struct ZoomableScreenshot: UIViewRepresentable {
    let image: UIImage
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
        return view
    }

    func updateUIView(_ view: ZoomView, context: Context) {
        context.coordinator.zoomChanged = zoomChanged
        context.coordinator.tapped = tapped
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
            (scrollView as? ZoomView)?.centerPhoto()
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard isZoomed != wasZoomed else { return }
            wasZoomed = isZoomed
            zoomChanged(isZoomed)
        }

        @objc func singleTapped() { tapped() }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? ZoomView else { return }
            if view.zoomScale > view.minimumZoomScale + 0.01 {
                view.setZoomScale(view.minimumZoomScale, animated: true)
            } else {
                // Zoom into the point that was tapped rather than the middle.
                let point = gesture.location(in: view.photo)
                let scale = ZoomView.doubleTapScale
                let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
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
            photo.layer.cornerRadius = 12
            addSubview(photo)
            minimumZoomScale = 1
            maximumZoomScale = 5
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            bouncesZoom = true
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

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
                if zoomScale <= minimumZoomScale + 0.01, !isDragging, !isZooming { settleInCenter() }
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
