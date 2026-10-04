#if REDLINE && canImport(UIKit)
import Photos
import PhotosUI
import SwiftUI

/// The photo panel. It grows out of the attachment button into a grid of recent photos.
/// Modeled on the photo picker in Trail's Ask chat, in Redline's black and white.
///
/// Like Trail's picker, Photos always opens this grid. Before the app has Photos access
/// the grid offers to show recent photos, which asks for access, or to open the system
/// photo picker, which runs outside the app and needs no permission.
struct AttachmentPicker: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expanded = false
    @State private var library = RecentPhotos()
    @State private var selectedIDs: [String] = []
    @State private var showsSystemPicker = false
    @State private var pickerItems: [PhotosPickerItem] = []

    static let selectionLimit = 10
    private let cornerRadius: CGFloat = 48
    private let columns = 3
    private let gridSpacing: CGFloat = 6
    private let gridInset: CGFloat = 12
    private let headerHeight: CGFloat = 60
    private let footerHeight: CGFloat = 78

    private var motion: Animation {
        reduceMotion ? .linear(duration: 0.12) : .interpolatingSpring(mass: 1, stiffness: 440, damping: 42, initialVelocity: 0)
    }

    /// The space inside the safe area, in screen points.
    private var bounds: CGRect {
        CGRect(
            x: 0,
            y: session.safeAreaTop,
            width: session.screenSize.width,
            height: session.screenSize.height - session.safeAreaTop - session.safeAreaInsets.bottom
        )
    }

    /// Every tile has the screen's shape, so a screenshot fills its tile whole and
    /// any other photo sits whole inside it.
    private var tileAspect: CGFloat {
        let size = session.screenSize
        return size.height > 0 ? size.width / size.height : 0.46
    }

    var body: some View {
        let anchor = session.attachAnchor
        let corner = AttachmentPlacement.corner(for: anchor, in: bounds)
        let frame = AttachmentPlacement.expanded(
            anchor: anchor,
            in: bounds,
            contentHeight: photosHeight(width: AttachmentPlacement.expanded(anchor: anchor, in: bounds).width)
        )
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityElement()
                .accessibilityLabel("Close attachments")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { close() }

            photosPage
                .frame(width: frame.width, height: frame.height)
            .background(Mono.surface)
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Mono.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            // Starts the size of the button and grows from the button's corner.
            .scaleEffect(
                x: expanded ? 1 : max(1, anchor.width) / max(frame.width, 1),
                y: expanded ? 1 : max(1, anchor.height) / max(frame.height, 1),
                anchor: corner.unitPoint
            )
            .opacity(expanded ? 1 : 0)
            .position(x: frame.midX, y: frame.midY)
        }
        .buttonStyle(.plain)
        .onAppear { withAnimation(motion) { expanded = true } }
        .task { await library.load() }
        .photosPicker(
            isPresented: $showsSystemPicker,
            selection: $pickerItems,
            maxSelectionCount: Self.selectionLimit,
            selectionBehavior: .ordered,
            matching: .images,
            // As stored, so a HEIC photo isn't converted to JPEG before the kit shrinks it anyway.
            preferredItemEncoding: .current
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            session.attachPhotos(previews: [], count: items.count, loading: Task { await Self.images(from: items) })
        }
    }

    /// The height the photos page needs: the header, the rows of tiles and the footer.
    private func photosHeight(width: CGFloat) -> CGFloat {
        guard !library.items.isEmpty else { return headerHeight + 170 + footerHeight }
        let tileWidth = (width - 2 * gridInset - CGFloat(columns - 1) * gridSpacing) / CGFloat(columns)
        let rows = CGFloat((library.items.count + columns - 1) / columns)
        let grid = rows * tileWidth / tileAspect + (rows - 1) * gridSpacing
        return headerHeight + grid + footerHeight
    }

    // MARK: - Photos

    private var photosPage: some View {
        VStack(spacing: 0) {
            Text("Recent photos")
                .font(.headline)
                .foregroundStyle(Mono.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .frame(height: headerHeight)
                .accessibilityAddTraits(.isHeader)

            if library.items.isEmpty {
                emptyPhotos
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns),
                        spacing: gridSpacing
                    ) {
                        ForEach(library.items) { item in
                            tile(item)
                        }
                    }
                    .padding(.horizontal, gridInset)
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                closeButton
                Spacer()
                if !selectedIDs.isEmpty {
                    Button(action: addSelected) {
                        Text("Add \(selectedIDs.count)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(Color.white, in: Capsule(style: .continuous))
                    }
                    .accessibilityLabel(selectedIDs.count == 1 ? "Add 1 photo" : "Add \(selectedIDs.count) photos")
                } else {
                    Button { showsSystemPicker = true } label: {
                        Text("All Photos")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Mono.text)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(Mono.fill, in: Capsule(style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 24)
            .frame(height: footerHeight)
        }
    }

    /// Before there is anything to show: a way to see recent photos, or the system picker.
    @ViewBuilder
    private var emptyPhotos: some View {
        VStack(spacing: 14) {
            if !library.isLoaded {
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(Mono.secondary)
            } else if library.canAskForAccess {
                Text("Your recent photos and screenshots show here.")
                    .font(.subheadline)
                    .foregroundStyle(Mono.secondary)
                    .multilineTextAlignment(.center)
                Button { Task { await library.requestAccess() } } label: {
                    Text("Show recent photos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(Color.white, in: Capsule(style: .continuous))
                }
                .accessibilityHint("Asks for access to your photos")
            } else if library.hasAccess {
                Text("No recent photos")
                    .font(.subheadline)
                    .foregroundStyle(Mono.secondary)
            } else {
                Text("Choose from your photo library.")
                    .font(.subheadline)
                    .foregroundStyle(Mono.secondary)
                Button { showsSystemPicker = true } label: {
                    Text("Open photo library")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 22)
                        .frame(height: 44)
                        .background(Color.white, in: Capsule(style: .continuous))
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(_ item: RecentPhotos.Item) -> some View {
        let order = selectedIDs.firstIndex(of: item.id)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            if let order {
                selectedIDs.remove(at: order)
            } else {
                guard selectedIDs.count < Self.selectionLimit else { return }
                selectedIDs.append(item.id)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Mono.fill
                .aspectRatio(tileAspect, contentMode: .fit)
                .overlay {
                    // The whole photo, never a crop of it.
                    Image(uiImage: item.thumbnail).resizable().scaledToFit()
                }
                .clipShape(shape)
                .overlay {
                    if order != nil {
                        // White with a black edge, like Redline's outlines, so it reads on any photo.
                        shape.strokeBorder(Color.black.opacity(0.75), lineWidth: 5)
                        shape.strokeBorder(Color.white, lineWidth: 3)
                    } else {
                        shape.strokeBorder(Mono.hairline, lineWidth: 1)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let order {
                        NumberBadge(number: order + 1, size: 26).padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Photo, \(item.createdAt.formatted(.relative(presentation: .named)))")
        .accessibilityAddTraits(order != nil ? .isSelected : [])
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Mono.text)
                .frame(width: 44, height: 44)
                .background(Mono.fill, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Close photos")
    }

    // MARK: - Actions

    /// Opens the note box at once with the grid's thumbnails; the full photos load behind it.
    private func addSelected() {
        let ids = selectedIDs
        let previews = ids.compactMap { id in library.items.first { $0.id == id }?.thumbnail }
        let library = library
        session.attachPhotos(previews: previews, count: ids.count, loading: Task { await library.images(for: ids) })
    }

    private func close() {
        withAnimation(motion, completionCriteria: .removed) {
            expanded = false
        } completion: {
            session.closeAttachments()
        }
    }

    /// Off the main thread and in parallel: reading and shrinking a large photo takes long
    /// enough to stall the UI. Keeps the order they were chosen in.
    nonisolated private static func images(from items: [PhotosPickerItem]) async -> [UIImage] {
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return (index, nil) }
                    return (index, PhotoLibrary.downscaled(data))
                }
            }
            var loaded = [UIImage?](repeating: nil, count: items.count)
            for await (index, image) in group { loaded[index] = image }
            return loaded.compactMap { $0 }
        }
    }
}

/// The newest photos and screenshots in Photos, for the grid. Empty without Photos access.
@MainActor
@Observable
final class RecentPhotos {
    struct Item: Identifiable {
        let id: String
        let createdAt: Date
        let thumbnail: UIImage
    }

    private(set) var items: [Item] = []
    private(set) var isLoaded = false
    @ObservationIgnored private var assets: [String: PHAsset] = [:]

    /// -RedlineSampleScreenshots YES fills the grid with the screenshots of
    /// reports already sent, for checking the grid on a simulator without changing its
    /// Photos library or permissions.
    private let usesSamples = UserDefaults.standard.bool(forKey: "RedlineSampleScreenshots")

    var hasAccess: Bool { usesSamples || PhotoLibrary.canRead }
    /// The app hasn't been asked for Photos access yet and can be.
    private(set) var canAskForAccess = false

    func requestAccess() async {
        guard await PhotoLibrary.requestAccess() else {
            canAskForAccess = false
            return
        }
        isLoaded = false
        await load()
    }

    func load() async {
        if usesSamples {
            items = Self.sampleFiles().compactMap { file in
                guard let image = UIImage(contentsOfFile: file.url.path) else { return nil }
                let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 240 * image.size.height / max(image.size.width, 1))) ?? image
                return Item(id: file.url.path, createdAt: file.date, thumbnail: thumbnail)
            }
            isLoaded = true
            return
        }
        canAskForAccess = PhotoLibrary.canAsk
        guard PhotoLibrary.canRead, !isLoaded else {
            isLoaded = true
            return
        }
        let found = PhotoLibrary.newestPhotos(limit: 30)
        assets = Dictionary(found.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var loaded: [Item] = []
        for asset in found {
            if let thumbnail = await PhotoLibrary.image(for: asset, pixels: 480) {
                loaded.append(Item(id: asset.localIdentifier, createdAt: asset.creationDate ?? .distantPast, thumbnail: thumbnail))
            }
        }
        items = loaded
        isLoaded = true
    }

    /// The chosen photos at attachment size, in the order they were chosen, all requested at once.
    func images(for ids: [String]) async -> [UIImage] {
        if usesSamples { return ids.compactMap { UIImage(contentsOfFile: $0) } }
        let requests = ids.compactMap { assets[$0] }.map { asset in
            Task { await PhotoLibrary.image(for: asset, pixels: PhotoLibrary.maxPixels) }
        }
        var images: [UIImage] = []
        for request in requests {
            if let image = await request.value { images.append(image) }
        }
        return images
    }
}

extension RecentPhotos {
    /// Images from sent reports, newest first.
    private static func sampleFiles() -> [(url: URL, date: Date)] {
        let files = FileManager.default
        let reports = (try? files.contentsOfDirectory(at: ReportStore.standard.reportsDirectory, includingPropertiesForKeys: nil)) ?? []
        var found: [(url: URL, date: Date)] = []
        for report in reports {
            let images = (try? files.contentsOfDirectory(at: report, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for image in images where image.pathExtension == "png" || image.pathExtension == "jpg" {
                let date = (try? image.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                found.append((url: image, date: date))
            }
        }
        found.sort { $0.date > $1.date }
        return Array(found.prefix(30))
    }
}

extension AttachmentPlacement.Corner {
    var unitPoint: UnitPoint {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
#endif
