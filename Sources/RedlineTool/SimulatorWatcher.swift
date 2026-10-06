#if os(macOS)
import CoreServices
import Foundation
import Synchronization

/// Watches the watched apps' folders in every simulator on this Mac.
///
/// A simulator app's files are ordinary files on the Mac, so macOS reports changes to them as they
/// happen: no `devicectl`, no network, and nothing that checks on a timer.
///
/// Every install moves an app's data container: a first install or a reinstall makes a new one,
/// and installing over a build, as Xcode's Run does, renames it. So the folders that list
/// simulators and containers are watched too, and each change there is a new look.
///
/// Thread safety: `owners`, `watched`, `roots`, `names`, `stream`, `folderSources`, `unwatchable`
/// and `isStopped` are read and written only on `queue`. What other threads read, the counts, is in `seen`, a
/// `Mutex`. The event stream holds this watcher unretained; the watcher lives as long as the hub,
/// which is the whole process.
final class SimulatorWatcher: @unchecked Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "Redline.hub.simulators", qos: .utility)
    private let devices: URL
    /// The containers in the simulators' folders and the app each belongs to, so a rescan reads only
    /// new ones.
    ///
    /// A container whose metadata couldn't be read yet, such as while the app is still installing,
    /// isn't kept, so the next rescan reads it again. One that's gone, moved by an install, is
    /// dropped.
    private var owners: [String: String] = [:]
    /// The watched apps' containers.
    private var watched: [String: String] = [:]
    /// The folders the event stream covers: each container's kit folders where they exist.
    private var roots: [String] = []
    private var names: [String: String] = [:]
    private var stream: FSEventStreamRef?
    /// The folders where simulators and containers come and go, by path; see `foldersToWatch(in:)`.
    private var folderSources: [String: any DispatchSourceFileSystemObject] = [:]
    /// Folders that couldn't be opened for watching, so each is logged once.
    private var unwatchable = Set<String>()
    /// Set by `stop()`, after which nothing is watched again.
    private var isStopped = false
    private let seen = Mutex(Seen())

    /// What the last rescan found, for other threads.
    private struct Seen {
        var containers = 0
        var simulators: Set<String> = []
    }

    var containerCount: Int { seen.withLock { $0.containers } }

    /// The simulators with a watched app installed.
    ///
    /// Memory only: never waits on `queue`.
    var simulatorIDs: Set<String> { seen.withLock { $0.simulators } }

    /// Does nothing until `rescan()`, so the hub has it in place before it first runs.
    ///
    /// `devices` is CoreSimulator's folder of simulators; tests give a folder of their own.
    init(
        hub: Hub,
        devices: URL = URL.libraryDirectory.appending(
            path: "Developer/CoreSimulator/Devices",
            directoryHint: .isDirectory
        )
    ) {
        self.hub = hub
        self.devices = devices
    }

    /// Finds the watched apps' containers, including apps installed or simulators created since
    /// the last look, watches them, and takes any report finished while nobody was watching.
    ///
    /// Also runs whenever a simulator or a container is added, removed or renamed.
    func rescan() {
        queue.async { self.rescanNow() }
    }

    private func rescanNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isStopped else { return }
        // Before listing the containers, so one that appears while they're listed wakes a new look.
        watchFolders()
        let found = watchedContainers()
        for (container, bundleID) in found { giveAddress(to: container, of: bundleID) }
        let roots = Self.roots(for: Array(found.keys))
        guard found != watched || roots != self.roots else { return }
        watched = found
        self.roots = roots
        let simulators = Set(found.keys.compactMap(SimulatorReportPath.device(ofContainer:)))
        seen.withLock { $0 = Seen(containers: found.count, simulators: simulators) }
        watch(roots)
        for container in found.keys { takeNewReports(in: container) }
        hub.writeStatus()
    }

    /// Waits until every look queued so far is done.
    func flush() {
        queue.sync {}
    }

    func stop() {
        queue.sync {
            isStopped = true
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            for source in folderSources.values { source.cancel() }
            folderSources = [:]
        }
    }

    /// The folders where a container or a simulator shows up, moves or goes away: the folder of
    /// simulators, and each simulator's folder of app data containers.
    ///
    /// A simulator that has never booted has no containers folder yet, so the deepest folder on the
    /// way to it is watched until it appears; the same goes for the folder of simulators before
    /// Xcode makes it. Watching only these folders, and not into them, keeps apps writing their own
    /// files from waking the hub.
    static func foldersToWatch(in devices: URL) -> [String] {
        let files = FileManager.default
        guard files.fileExists(atPath: devices.path) else {
            return deepestFolder(on: devices).map { [$0] } ?? []
        }
        let simulators = ((try? files.contentsOfDirectory(atPath: devices.path)) ?? [])
            .map { devices.appending(path: $0, directoryHint: .isDirectory) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let applications = simulators.compactMap { simulator in
            deepestFolder(
                on: simulator.appending(path: "data/Containers/Data/Application", directoryHint: .isDirectory)
            )
        }
        return ([devices.path] + applications).sorted()
    }

    /// `folder` when it exists, or else the nearest folder above it that does.
    private static func deepestFolder(on folder: URL) -> String? {
        var folder = folder.standardizedFileURL
        while !FileManager.default.fileExists(atPath: folder.path) {
            let parent = folder.deletingLastPathComponent()
            guard parent.path != folder.path else { return nil }
            folder = parent
        }
        return folder.path
    }

    /// Watches `foldersToWatch(in:)`, so each change in them is a new look.
    ///
    /// A folder made between finding them and watching them would wake nothing, so they're found
    /// again until nothing new appears. A watched folder that's deleted or renamed, as when a
    /// simulator is erased, is watched again at its path by the look its event starts. A folder
    /// that can't be opened is tried once per look, and said once in the log.
    private func watchFolders() {
        dispatchPrecondition(condition: .onQueue(queue))
        var tried = Set<String>()
        // A pass repeats only when a folder appeared while the last one was opening its parent, so
        // the worst case is one level a pass: from ~/Library to a containers folder is eight levels
        // (Developer, CoreSimulator, Devices, the simulator, data, Containers, Data, Application).
        for _ in 0..<8 {
            let wanted = Set(Self.foldersToWatch(in: devices))
            for (folder, source) in folderSources where !wanted.contains(folder) {
                source.cancel()
                folderSources[folder] = nil
            }
            let new = wanted.subtracting(folderSources.keys).subtracting(tried)
            guard !new.isEmpty else { return }
            for folder in new {
                tried.insert(folder)
                let descriptor = open(folder, O_EVTONLY)
                guard descriptor >= 0 else {
                    // ENOENT is a folder removed meanwhile, which its parent's event covers.
                    if errno != ENOENT, unwatchable.insert(folder).inserted {
                        hub.log("Couldn't watch \(folder) for simulator installs: \(String(cString: strerror(errno)))")
                    }
                    continue
                }
                unwatchable.remove(folder)
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename],
                    queue: queue
                )
                source.setEventHandler { [unowned self, unowned source] in
                    if !source.data.isDisjoint(with: [.delete, .rename]) {
                        source.cancel()
                        if folderSources[folder] === source { folderSources[folder] = nil }
                    }
                    rescanNow()
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                folderSources[folder] = source
            }
        }
    }

    private func watchedContainers() -> [String: String] {
        dispatchPrecondition(condition: .onQueue(queue))
        let files = FileManager.default
        var found: [String: String] = [:]
        var listed = Set<String>()
        let simulators = (try? files.contentsOfDirectory(atPath: devices.path)) ?? []
        defer { owners = owners.filter { listed.contains($0.key) } }
        for simulator in simulators {
            let applications = devices.appending(
                path: "\(simulator)/data/Containers/Data/Application",
                directoryHint: .isDirectory
            )
            for container in (try? files.contentsOfDirectory(atPath: applications.path)) ?? [] {
                let path = applications.appending(path: container).path
                listed.insert(path)
                if owners[path] == nil {
                    let metadata = URL(filePath: path).appending(
                        path: ".com.apple.mobile_container_manager.metadata.plist"
                    )
                    let plist = (try? Data(contentsOf: metadata)).flatMap {
                        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                    }
                    if let owner = plist?["MCMMetadataIdentifier"] as? String, !owner.isEmpty {
                        owners[path] = owner
                    }
                }
                if let owner = owners[path], hub.apps.contains(owner) { found[path] = owner }
            }
        }
        return found
    }

    /// Leaves the hub's address in a simulator app's folder, so the app can ask which chats a
    /// report can go to.
    ///
    /// It doesn't upload: the hub takes simulator reports from the folder.
    private func giveAddress(to container: String, of bundleID: String) {
        guard let device = SimulatorReportPath.device(ofContainer: container) else { return }
        let address = HubMessage.Address(
            device: device,
            hosts: ["127.0.0.1"],
            port: HubListener.port,
            token: hub.issueToken(device: device, bundleID: bundleID),
            uploads: false
        )
        let data = HubMessage.encode(address)
        for file in Self.addressFiles(in: container) where (try? Data(contentsOf: file)) != data {
            do {
                try Self.makeFolder(file.deletingLastPathComponent(), inside: container)
                try data.write(to: file, options: .atomic)
            } catch {
                // An install moved the container meanwhile; the look its move starts writes it there.
                guard FileManager.default.fileExists(atPath: container) else { continue }
                hub.log(
                    "Couldn't leave the hub's address for \(bundleID) in simulator \(device): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Makes `folder` and the folders above it, one at a time, up to `container`, which it never
    /// makes.
    ///
    /// An install can move a container at any moment, so making the folders with their parents in
    /// one step could make the container again at its old path, holding nothing but the kit's folder.
    static func makeFolder(_ folder: URL, inside container: String) throws {
        let base = URL(filePath: container, directoryHint: .isDirectory).standardizedFileURL
        let target = folder.standardizedFileURL
        let names = target.pathComponents.dropFirst(base.pathComponents.count)
        guard target.pathComponents.starts(with: base.pathComponents) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var path = base
        for name in names {
            path.append(path: name, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else { continue }
            do {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // The app made it meanwhile.
            }
        }
    }

    /// Where to leave the hub's address in a simulator app's folder: under the new name, and under
    /// the old one while a build from before the rename has its folder there.
    ///
    /// Only then, so a renamed build, which removes that folder, doesn't get it back.
    static func addressFiles(in container: String) -> [URL] {
        let base = URL(filePath: container)
        let earlier = base.appending(path: HubMessage.earlierAddressPath)
        let earlierKit = earlier.deletingLastPathComponent().path(percentEncoded: false)
        return [base.appending(path: HubMessage.addressPath)]
            + (FileManager.default.fileExists(atPath: earlierKit) ? [earlier] : [])
    }

    /// The kit's folders where they exist, so the app's own writes don't wake the hub; the whole
    /// container until the kit has written anything.
    ///
    /// A build from before the rename keeps its reports under the old name, so that folder is
    /// watched as well while it's there.
    static func roots(for containers: [String]) -> [String] {
        containers.flatMap { container in
            let kits = [HubMessage.kitFolder, HubMessage.earlierKitFolder].map { container + "/" + $0 }
                .filter { FileManager.default.fileExists(atPath: $0) }
            return kits.isEmpty ? [container] : kits
        }.sorted()
    }

    private func watch(_ roots: [String]) {
        dispatchPrecondition(condition: .onQueue(queue))
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<SimulatorWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // macOS dropped events or merged them into a folder: the paths don't name every change.
            let incomplete = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
            )
            let isIncomplete = (0..<count).contains { flags[$0] & incomplete != 0 }
            watcher.filesDidChange(at: Array(changed.prefix(count)), isIncomplete: isIncomplete)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard
            let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3,
                flags
            )
        else {
            hub.log("Couldn't watch the simulators")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Runs on `queue`, called by the event stream.
    ///
    /// When the events are `isIncomplete`, such as when macOS dropped some, every watched app's
    /// reports are looked at, so none waits for the next unrelated change.
    private func filesDidChange(at paths: [String], isIncomplete: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        if isIncomplete {
            for container in watched.keys { takeNewReports(in: container) }
            return
        }
        for report in Set(paths.compactMap(SimulatorReportPath.parse)) {
            take(reportID: report.reportID, in: report.container, from: report.folder)
        }
    }

    private func takeNewReports(in container: String) {
        for reports in ReportFolder.paths {
            let folder = URL(filePath: container).appending(path: reports, directoryHint: .isDirectory)
            for id in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                take(reportID: id, in: container, from: reports)
            }
        }
    }

    /// Takes a report from `reports`, one of the container's `ReportFolder.paths`.
    private func take(reportID: String, in container: String, from reports: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let bundleID = watched[container],
            let path = SimulatorReportPath.parse(container + "/" + reports + "/" + reportID + "/")
        else { return }
        let files = FileManager.default
        let folder = URL(filePath: container).appending(
            path: reports + "/" + reportID,
            directoryHint: .isDirectory
        )
        let entries = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).map {
            name -> (path: String, modified: Date?) in
            let attributes = try? files.attributesOfItem(atPath: folder.appending(path: name).path)
            return ("\(reportID)/\(name)", attributes?[.modificationDate] as? Date)
        }
        let finished = ReportFolder.finishedReports(in: entries)
        if !hub.reportIDsToCopy(device: path.device, bundleID: bundleID, finished: finished).isEmpty {
            let source = ReportSource(
                kind: .simulator,
                device: path.device,
                deviceName: name(of: path.device),
                bundleID: bundleID,
                reportID: reportID,
                receivedAt: .now
            )
            do {
                try hub.receive(source) { destination in
                    try files.copyItem(at: folder, to: destination)
                    // The copy keeps links as links. Checked in the copy, which the app can't change.
                    guard Self.holdsOnlyFilesAndFolders(destination) else { throw TakeError.specialFile }
                }
            } catch {
                // The hub logged why; the report isn't counted as delivered, so it's taken at the next look.
                return
            }
        }
        // The mark the app shows as "On the Mac", and waits for after Send; a phone's app makes it
        // when the hub's reply says so.
        let mark = folder.appending(path: ReportFolder.deliveredMark)
        guard hub.settledReportIDs(device: path.device, bundleID: bundleID, finished: finished).contains(reportID),
            !files.fileExists(atPath: mark.path)
        else { return }
        if !files.createFile(atPath: mark.path, contents: nil) {
            hub.log("Couldn't mark report \(reportID) of \(bundleID) in \(name(of: path.device)) as on the Mac")
        }
    }

    /// Why a simulator report wasn't taken.
    enum TakeError: Error, LocalizedError {
        /// The report holds a link or another special file.
        case specialFile

        var errorDescription: String? {
            switch self {
            case .specialFile: "The report holds a link or another special file"
            }
        }
    }

    /// True when `item` is a folder of plain files and folders, or a plain file: no symbolic link,
    /// hard link, device or pipe.
    ///
    /// A simulator app writes its report folder itself, so a link in it could lead the hub, or a
    /// chat reading the report, to any file on the Mac.
    static func holdsOnlyFilesAndFolders(_ item: URL) -> Bool {
        var info = stat()
        guard lstat(item.path(percentEncoded: false), &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return info.st_nlink == 1
        case S_IFDIR:
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: item.path(percentEncoded: false))
            else { return false }
            return names.allSatisfy { holdsOnlyFilesAndFolders(item.appending(path: $0)) }
        default:
            return false
        }
    }

    private func name(of simulator: String) -> String {
        dispatchPrecondition(condition: .onQueue(queue))
        if let name = names[simulator] { return name }
        let plist = (try? Data(contentsOf: devices.appending(path: "\(simulator)/device.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let name = plist?["name"] as? String ?? simulator
        names[simulator] = name
        return name
    }
}
#endif
