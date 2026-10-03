#if AGENTIC_DEBUGGING && canImport(UIKit)
import Photos
import PhotosUI
import SwiftUI

/// The attachment surface. It grows out of the attachment button as a small menu,
/// and the menu opens into a grid of recent screenshots in place. Modeled on the photo
/// picker in Trail's Ask chat, in the debugger's black and white.
///
/// The grid needs Photos access the app already has. Without it, Screenshots opens the
/// system photo picker instead, which runs outside the app and needs no permission.
struct AttachmentPicker: View {
    @Bindable var session: DebugSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Page { case menu, screenshots }
    @State private var page = Page.menu
    @State private var expanded = false
    @State private var library = RecentScreenshots()
    @State private var selectedIDs: [String] = []
    @State private var showsSystemPicker = false
    @State private var systemPickerFilter = PHPickerFilter.screenshots
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isLoading = false

    static let selectionLimit = 10
    private let cornerRadius: CGFloat = 48

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

    var body: some View {
        let anchor = session.attachAnchor
        let corner = AttachmentPlacement.corner(for: anchor, in: bounds)
        let frame = page == .menu
            ? AttachmentPlacement.menu(anchor: anchor, in: bounds)
            : AttachmentPlacement.expanded(anchor: anchor, in: bounds)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityElement()
                .accessibilityLabel("Close attachments")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { close() }

            ZStack {
                menu
                    .opacity(page == .menu ? 1 : 0)
                    .allowsHitTesting(page == .menu)
                    .accessibilityHidden(page != .menu)
                screenshotsPage
                    .opacity(page == .screenshots ? 1 : 0)
                    .allowsHitTesting(page == .screenshots)
                    .accessibilityHidden(page != .screenshots)
            }
            .frame(width: frame.width, height: frame.height, alignment: corner.isTop ? .top : .bottom)
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
            matching: systemPickerFilter
        )
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            attach { await Self.images(from: items) }
        }
    }

    // MARK: - Menu

    private var menu: some View {
        VStack(spacing: 0) {
            Button(action: session.attachThisScreen) {
                menuLabel("This screen", symbol: "iphone")
            }
            .accessibilityHint("Attaches the app as it looks now")
            Button(action: openScreenshots) {
                menuLabel("Screenshots", symbol: "photo.on.rectangle")
            }
            .accessibilityHint("Choose recent screenshots to attach")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private func menuLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 44)
                .background(Mono.fill, in: Circle())
            Text(title)
            Spacer()
        }
        .font(.system(size: 20))
        .foregroundStyle(Mono.text)
        .frame(height: 66)
        .contentShape(Rectangle())
    }

    private func openScreenshots() {
        if library.canShowGrid {
            withAnimation(motion) { page = .screenshots }
        } else {
            systemPickerFilter = .screenshots
            showsSystemPicker = true
        }
    }

    // MARK: - Screenshots

    private var screenshotsPage: some View {
        VStack(spacing: 0) {
            Text("Recent screenshots")
                .font(.headline)
                .foregroundStyle(Mono.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .frame(height: 60)
                .accessibilityAddTraits(.isHeader)

            if library.items.isEmpty {
                VStack(spacing: 12) {
                    Text(library.isLoaded ? "No screenshots from the last while" : "Loading…")
                        .font(.subheadline)
                        .foregroundStyle(Mono.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                        ForEach(library.items) { item in
                            tile(item)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                backButton
                Spacer()
                if isLoading {
                    ProgressView().tint(Mono.text).frame(width: 44, height: 44)
                } else if !selectedIDs.isEmpty {
                    Button(action: addSelected) {
                        Text("Add \(selectedIDs.count)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(Color.white, in: Capsule(style: .continuous))
                    }
                    .accessibilityLabel(selectedIDs.count == 1 ? "Add 1 screenshot" : "Add \(selectedIDs.count) screenshots")
                } else {
                    Button {
                        systemPickerFilter = .images
                        showsSystemPicker = true
                    } label: {
                        Text("All Photos")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Mono.text)
                            .padding(.horizontal, 20)
                            .frame(height: 44)
                            .background(Mono.fill, in: Capsule(style: .continuous))
                    }
                }
            }
            .frame(height: 64)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    private func tile(_ item: RecentScreenshots.Item) -> some View {
        let order = selectedIDs.firstIndex(of: item.id)
        return Button {
            if let order {
                selectedIDs.remove(at: order)
            } else {
                guard selectedIDs.count < Self.selectionLimit else { return }
                selectedIDs.append(item.id)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .top) {
                    // The top of a screenshot, where its title is, says the most about it.
                    Image(uiImage: item.thumbnail).resizable().scaledToFill()
                }
                .clipped()
                .overlay {
                    if order != nil {
                        // White with a black edge, like the debugger's outlines, so it reads on any screenshot.
                        Rectangle().strokeBorder(Color.black.opacity(0.75), lineWidth: 5)
                        Rectangle().strokeBorder(Color.white, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let order {
                        NumberBadge(number: order + 1, size: 26).padding(8)
                    }
                }
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Screenshot, \(item.createdAt.formatted(.relative(presentation: .named)))")
        .accessibilityAddTraits(order != nil ? .isSelected : [])
    }

    private var backButton: some View {
        Button {
            selectedIDs = []
            withAnimation(motion) { page = .menu }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Mono.text)
                .frame(width: 44, height: 44)
                .background(Mono.fill, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Back to attachments")
    }

    // MARK: - Actions

    private func addSelected() {
        let ids = selectedIDs
        attach { await library.images(for: ids) }
    }

    /// Loads the chosen images, then opens the note box for them.
    private func attach(_ load: @escaping @MainActor () async -> [UIImage]) {
        isLoading = true
        Task {
            let images = await load()
            isLoading = false
            session.attachPhotos(images)
        }
    }

    private func close() {
        withAnimation(motion, completionCriteria: .removed) {
            expanded = false
        } completion: {
            session.closeAttachments()
        }
    }

    private static func images(from items: [PhotosPickerItem]) async -> [UIImage] {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = PhotoLibrary.downscaled(data) {
                images.append(image)
            }
        }
        return images
    }
}

/// The newest screenshots in Photos, for the grid. Empty without Photos access.
@MainActor
@Observable
final class RecentScreenshots {
    struct Item: Identifiable {
        let id: String
        let createdAt: Date
        let thumbnail: UIImage
    }

    private(set) var items: [Item] = []
    private(set) var isLoaded = false
    @ObservationIgnored private var assets: [String: PHAsset] = [:]

    /// -AgenticDebuggingSampleScreenshots YES fills the grid with the screenshots of
    /// reports already sent, for checking the grid on a simulator without changing its
    /// Photos library or permissions.
    private let usesSamples = UserDefaults.standard.bool(forKey: "AgenticDebuggingSampleScreenshots")

    /// The grid only shows when the app already has Photos access.
    var canShowGrid: Bool { usesSamples || PhotoLibrary.canRead }

    func load() async {
        if usesSamples {
            items = Self.sampleFiles().compactMap { file in
                guard let image = UIImage(contentsOfFile: file.url.path), let thumbnail = DebugSession.topSquare(of: image) else { return nil }
                return Item(id: file.url.path, createdAt: file.date, thumbnail: thumbnail)
            }
            isLoaded = true
            return
        }
        guard PhotoLibrary.canRead, !isLoaded else {
            isLoaded = true
            return
        }
        let found = PhotoLibrary.newestScreenshots(limit: 30)
        assets = Dictionary(found.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var loaded: [Item] = []
        for asset in found {
            if let thumbnail = await PhotoLibrary.image(for: asset, pixels: 300, fill: true) {
                loaded.append(Item(id: asset.localIdentifier, createdAt: asset.creationDate ?? .distantPast, thumbnail: thumbnail))
            }
        }
        items = loaded
        isLoaded = true
    }

    /// The chosen screenshots at attachment size, in the order they were chosen.
    func images(for ids: [String]) async -> [UIImage] {
        if usesSamples { return ids.compactMap { UIImage(contentsOfFile: $0) } }
        var images: [UIImage] = []
        for id in ids {
            if let asset = assets[id], let image = await PhotoLibrary.image(for: asset, pixels: PhotoLibrary.maxPixels) {
                images.append(image)
            }
        }
        return images
    }
}

extension RecentScreenshots {
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
