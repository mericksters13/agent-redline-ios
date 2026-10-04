#if os(macOS)
import CoreServices
import Foundation

/// Watches the watched apps' folders in every simulator on this Mac. A simulator app's files
/// are ordinary files on the Mac, so macOS reports changes to them as they happen: no
/// `devicectl`, no network, and nothing that checks on a timer.
final class SimulatorWatcher: @unchecked Sendable {
    private unowned let hub: Hub
    private let queue = DispatchQueue(label: "simulators")
    private let devices = URL.libraryDirectory.appending(path: "Developer/CoreSimulator/Devices", directoryHint: .isDirectory)
    /// Every app data container seen so far and the app it belongs to, so a rescan reads only
    /// new ones. A container whose metadata couldn't be read yet, such as while the app is
    /// still installing, isn't kept, so the next rescan reads it again.
    private var owners: [String: String] = [:]
    /// The watched apps' containers.
    private var watched: [String: String] = [:]
    /// The folders the event stream covers: each container's kit folder where it exists.
    private var roots: [String] = []
    private var names: [String: String] = [:]
    private var stream: FSEventStreamRef?
    private var count = 0
    private let lock = NSLock()

    var containerCount: Int { lock.withLock { count } }

    init(hub: Hub) {
        self.hub = hub
        rescan()
    }

    /// Finds the watched apps' containers, including apps installed or simulators created since
    /// the last look, watches them, and takes any report finished while nobody was watching.
    func rescan() {
        queue.async {
            let found = self.watchedContainers()
            for (container, bundleID) in found { self.giveAddress(to: container, of: bundleID) }
            let roots = Self.roots(for: Array(found.keys))
            guard found != self.watched || roots != self.roots else { return }
            self.watched = found
            self.roots = roots
            self.lock.withLock { self.count = found.count }
            self.watch(roots)
            for container in found.keys { self.takeNewReports(in: container) }
            self.hub.writeStatus()
        }
    }

    /// The simulators with a watched app installed, from their containers' paths.
    var simulatorIDs: Set<String> {
        let containers = queue.sync { Array(watched.keys) }
        return Set(containers.compactMap { path in
            let parts = path.split(separator: "/")
            return parts.firstIndex(of: "Devices").flatMap { parts.indices.contains($0 + 1) ? String(parts[$0 + 1]) : nil }
        })
    }

    func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
    }

    private func watchedContainers() -> [String: String] {
        let files = FileManager.default
        var found: [String: String] = [:]
        let simulators = (try? files.contentsOfDirectory(atPath: devices.path)) ?? []
        for simulator in simulators {
            let applications = devices.appending(path: "\(simulator)/data/Containers/Data/Application", directoryHint: .isDirectory)
            for container in (try? files.contentsOfDirectory(atPath: applications.path)) ?? [] {
                let path = applications.appending(path: container).path
                if owners[path] == nil {
                    let metadata = URL(fileURLWithPath: path).appending(path: ".com.apple.mobile_container_manager.metadata.plist")
                    let plist = (try? Data(contentsOf: metadata)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                    if let owner = plist?["MCMMetadataIdentifier"] as? String, !owner.isEmpty { owners[path] = owner }
                }
                if let owner = owners[path], hub.apps.contains(owner) { found[path] = owner }
            }
        }
        return found
    }

    /// Leaves the hub's address in a simulator app's folder, so the app can ask which chats a
    /// report can go to. It doesn't upload: the hub takes simulator reports from the folder.
    private func giveAddress(to container: String, of bundleID: String) {
        guard let path = SimulatorReportPath.parse(container + "/" + ReportFolder.path + "/x/") else { return }
        let address = HubMessage.Address(device: path.device, hosts: ["127.0.0.1"], port: HubListener.port,
                                         token: hub.token(device: path.device, bundleID: bundleID), uploads: false)
        let file = URL(fileURLWithPath: container).appending(path: HubMessage.addressPath)
        let data = HubMessage.encode(address)
        guard (try? Data(contentsOf: file)) != data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The kit's folder where it exists, so the app's own writes don't wake the hub; the whole
    /// container until the kit has written anything.
    private static func roots(for containers: [String]) -> [String] {
        containers.map { container in
            let kit = container + "/Library/Application Support/iOSAgenticDebuggingKit"
            return FileManager.default.fileExists(atPath: kit) ? kit : container
        }.sorted()
    }

    private func watch(_ roots: [String]) {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<SimulatorWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // macOS dropped events or merged them into a folder: the paths don't name every change.
            let incomplete = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let dropped = (0..<count).contains { flags[$0] & incomplete != 0 }
            watcher.changed(Array(changed.prefix(count)), dropped: dropped)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else {
            hub.log("Couldn't watch the simulators")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Runs on `queue`, called by the event stream. When events were `dropped`, every watched
    /// app's reports are looked at, so none waits for the next unrelated change.
    private func changed(_ paths: [String], dropped: Bool) {
        if dropped {
            for container in watched.keys { takeNewReports(in: container) }
            return
        }
        let reports = Set(paths.compactMap { SimulatorReportPath.parse($0).map { "\($0.container)\n\($0.reportID)" } })
        for key in reports {
            let parts = key.split(separator: "\n").map(String.init)
            take(reportID: parts[1], in: parts[0])
        }
    }

    private func takeNewReports(in container: String) {
        let folder = URL(fileURLWithPath: container).appending(path: ReportFolder.path, directoryHint: .isDirectory)
        for id in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            take(reportID: id, in: container)
        }
    }

    private func take(reportID: String, in container: String) {
        guard let bundleID = watched[container], let path = SimulatorReportPath.parse(container + "/" + ReportFolder.path + "/" + reportID + "/") else { return }
        let files = FileManager.default
        let folder = URL(fileURLWithPath: container).appending(path: ReportFolder.path + "/" + reportID, directoryHint: .isDirectory)
        let entries = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).map { name -> (path: String, modified: Date?) in
            let attributes = try? files.attributesOfItem(atPath: folder.appending(path: name).path)
            return ("\(reportID)/\(name)", attributes?[.modificationDate] as? Date)
        }
        let finished = ReportFolder.finished(in: entries)
        if !hub.toCopy(device: path.device, bundleID: bundleID, finished: finished).isEmpty {
            let source = ReportSource(kind: .simulator, device: path.device, deviceName: name(of: path.device), bundleID: bundleID, reportID: reportID, receivedAt: Date())
            let copied = hub.receive(source) { destination in
                guard (try? files.copyItem(at: folder, to: destination)) != nil else { return false }
                // The copy keeps links as links. Checked in the copy, which the app can't change.
                guard Self.holdsOnlyFilesAndFolders(destination) else {
                    hub.log("Report \(reportID) of \(bundleID) holds a link or another special file; not taken")
                    return false
                }
                return true
            }
            guard copied else { return }
        }
        // The mark the app shows as "On the Mac"; a phone's app makes it when the hub's reply says so.
        let mark = folder.appending(path: ReportFolder.deliveredMark)
        if hub.settled(device: path.device, bundleID: bundleID, finished: finished).contains(reportID), !files.fileExists(atPath: mark.path) {
            files.createFile(atPath: mark.path, contents: nil)
        }
    }

    /// True when `item` is a folder of plain files and folders, or a plain file: no symbolic
    /// link, hard link, device or pipe. A simulator app writes its report folder itself, so a
    /// link in it could lead the hub, or a chat reading the report, to any file on the Mac.
    static func holdsOnlyFilesAndFolders(_ item: URL) -> Bool {
        var info = stat()
        guard lstat(item.path, &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            return info.st_nlink == 1
        case S_IFDIR:
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: item.path) else { return false }
            return names.allSatisfy { holdsOnlyFilesAndFolders(item.appending(path: $0)) }
        default:
            return false
        }
    }

    private func name(of simulator: String) -> String {
        if let name = names[simulator] { return name }
        let plist = (try? Data(contentsOf: devices.appending(path: "\(simulator)/device.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let name = plist?["name"] as? String ?? simulator
        names[simulator] = name
        return name
    }
}
#endif
