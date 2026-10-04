#if os(macOS)
import Foundation

/// A build of an app and the chat that made it. Every build of a binary gets its own UUID from
/// the linker; the app sends its UUIDs with each report, so the report goes to the chat that
/// built what's on the device.
struct BuildRecord: Codable, Equatable, Sendable {
    var ids: [String]
    var bundleID: String
    var app: String
    var modified: Date
    /// The chat's record ID, such as `claude-<session ID>`.
    var chat: String
    var agent: String
    /// The worktree the build came from.
    var folder: String
}

/// A built app found in a derived data folder.
struct BuiltApp: Equatable {
    var app: URL
    var bundleID: String
    /// The executable, and the debug dylib a Debug build keeps the app's code in.
    var binaries: [URL]
    var modified: Date
    /// The worktree its project is in.
    var folder: String
    /// The derived data folder it was built into.
    var derivedData: URL
}

enum Builds {
    /// A build counts as the chat's only if it finished this recently when the chat's hook
    /// looked, so a chat never takes credit for an old build.
    static let freshness: TimeInterval = 900
    static let kept = 300
    /// A build from another folder counts as the chat's only right after the chat ran a build
    /// command that names that folder, and only if it finished this recently.
    static let justBuilt: TimeInterval = 120

    static func file(_ paths: HubPaths) -> URL { paths.hub.appending(path: "builds.json") }

    static func all(_ paths: HubPaths) -> [BuildRecord] {
        (try? Data(contentsOf: file(paths))).flatMap { try? Chats.decoder.decode([BuildRecord].self, from: $0) } ?? []
    }

    /// The newest build with any of these UUIDs.
    static func find(_ ids: [String], paths: HubPaths) -> BuildRecord? {
        let wanted = Set(ids)
        return all(paths).last { !wanted.isDisjoint(with: $0.ids) }
    }

    /// True when the chat built any app.
    static func madeBy(_ chat: String, paths: HubPaths) -> Bool {
        all(paths).contains { $0.chat == chat }
    }

    /// Records the apps built from the chat's worktree since the last look as the chat's.
    /// Returns what it recorded.
    @discardableResult
    /// `buildCommand` is a build command the chat just ran, which may build a project outside
    /// the chat's folder: a build there counts only if the command names its folder, so a
    /// build another chat finished at the same moment doesn't. `bundleIDs` is asked for only
    /// when there's a new build in the chat's own folder: it reads the project.
    static func record(chat: String, agent: String, folder: String, paths: HubPaths, roots: [URL]? = nil,
                       now: Date = Date(), buildCommand: String? = nil, bundleIDs: () -> [String]) -> [BuildRecord] {
        let worktree = worktreeRoot(of: folder)
        let fresh = builtApps(roots: roots ?? derivedDataFolders(around: worktree)).filter {
            let age = now.timeIntervalSince($0.modified)
            if $0.folder == worktree { return age < freshness }
            guard let command = buildCommand, age < justBuilt else { return false }
            return command.contains($0.folder) || command.contains($0.derivedData.path)
        }
        guard !fresh.isEmpty else { return [] }
        return withLock(paths) {
            var records = all(paths)
            // Saved times keep whole seconds only.
            let new = fresh.filter { built in !records.contains { $0.app == built.app.path && $0.modified > built.modified.addingTimeInterval(-1) } }
            guard !new.isEmpty else { return [] }
            // The chat's own project's apps; elsewhere, the app its build command just built.
            let apps = new.contains { $0.folder == worktree } ? Set(bundleIDs()) : []
            var added: [BuildRecord] = []
            for built in new where built.folder != worktree || apps.contains(built.bundleID) {
                let ids = built.binaries.flatMap(machOUUIDs)
                guard !ids.isEmpty else { continue }
                // Whole seconds, as it's saved.
                let modified = Date(timeIntervalSince1970: built.modified.timeIntervalSince1970.rounded(.down))
                let record = BuildRecord(ids: ids, bundleID: built.bundleID, app: built.app.path, modified: modified,
                                         chat: chat, agent: agent, folder: built.folder)
                records.append(record)
                added.append(record)
            }
            if !added.isEmpty {
                try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
                try? Chats.coder.encode(Array(records.suffix(kept))).write(to: file(paths), options: .atomic)
            }
            return added
        }
    }

    /// The worktree an app with one of these UUIDs was built from, for a build no chat made,
    /// such as one built in Xcode by hand.
    static func folder(of ids: [String], bundleID: String, roots: [URL]? = nil) -> String? {
        let wanted = Set(ids)
        return builtApps(roots: roots ?? derivedDataFolders(around: nil))
            .filter { $0.bundleID == bundleID }
            .first { !wanted.isDisjoint(with: $0.binaries.flatMap(machOUUIDs)) }?.folder
    }

    /// Where Xcode, XcodeBuildMCP and project scripts put builds.
    static func derivedDataFolders(around worktree: String?) -> [URL] {
        let files = FileManager.default
        let developer = files.homeDirectoryForCurrentUser.appending(path: "Library/Developer", directoryHint: .isDirectory)
        func children(_ folder: URL) -> [URL] {
            (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        var folders = children(developer.appending(path: "Xcode/DerivedData"))
        for workspace in children(developer.appending(path: "XcodeBuildMCP/workspaces")) {
            folders += children(workspace.appending(path: "DerivedData"))
        }
        if let worktree {
            folders += [".build/xcode", "build", "DerivedData", ".derivedData"].map { URL(fileURLWithPath: worktree).appending(path: $0) }
        }
        return folders
    }

    /// The apps in these derived data folders, each with the worktree of the project built.
    static func builtApps(roots: [URL]) -> [BuiltApp] {
        let files = FileManager.default
        var apps: [BuiltApp] = []
        for root in roots {
            guard let info = NSDictionary(contentsOf: root.appending(path: "info.plist")),
                  let workspace = info["WorkspacePath"] as? String
            else { continue }
            let folder = worktreeRoot(of: workspace)
            let products = root.appending(path: "Build/Products", directoryHint: .isDirectory)
            for configuration in (try? files.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [] {
                for app in (try? files.contentsOfDirectory(at: configuration, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                    guard let plist = NSDictionary(contentsOf: app.appending(path: "Info.plist")),
                          let bundleID = plist["CFBundleIdentifier"] as? String, let executable = plist["CFBundleExecutable"] as? String,
                          // UI test runners never send reports.
                          !bundleID.hasSuffix(".xctrunner")
                    else { continue }
                    let binaries = [executable, executable + ".debug.dylib"].map { app.appending(path: $0) }.filter { files.fileExists(atPath: $0.path) }
                    let modified = binaries.compactMap { (try? files.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.max()
                    guard let modified else { continue }
                    apps.append(BuiltApp(app: app, bundleID: bundleID, binaries: binaries, modified: modified, folder: folder, derivedData: root))
                }
            }
        }
        return apps
    }

    /// The folder holding `.git` above a path: the worktree, which is what tells chats apart.
    static func worktreeRoot(of path: String) -> String {
        let files = FileManager.default
        var folder = URL(fileURLWithPath: path).standardizedFileURL
        var isFolder: ObjCBool = false
        if !files.fileExists(atPath: folder.path, isDirectory: &isFolder) || !isFolder.boolValue || folder.pathExtension == "xcodeproj" {
            folder = folder.deletingLastPathComponent()
        }
        var candidate = folder
        while candidate.path != "/" {
            if files.fileExists(atPath: candidate.appending(path: ".git").path) { return candidate.path }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder.path
    }

    /// The UUIDs in a Mach-O file, one per architecture.
    static func machOUUIDs(_ file: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data {
            (try? handle.seek(toOffset: offset)).flatMap { _ in try? handle.read(upToCount: count) } ?? Data()
        }
        let start = read(0, 4096)
        guard start.count >= 8 else { return [] }
        let magic = start.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        // Fat files list each architecture's slice, big-endian.
        if magic == 0xBEBA_FECA || magic == 0xBFBA_FECA {
            let wide = magic == 0xBFBA_FECA
            let count = UInt32(bigEndian: start.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
            var ids: [String] = []
            for index in 0..<Int(min(count, 16)) {
                let entry = 8 + index * (wide ? 32 : 20)
                guard start.count >= entry + (wide ? 32 : 20) else { break }
                let offset = wide
                    ? UInt64(bigEndian: start.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entry + 8, as: UInt64.self) })
                    : UInt64(UInt32(bigEndian: start.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: entry + 8, as: UInt32.self) }))
                if let id = thinUUID(read(offset, 65_536)) { ids.append(id) }
            }
            return ids
        }
        return thinUUID(read(0, 65_536)).map { [$0] } ?? []
    }

    /// The UUID in a 64-bit Mach-O header and its load commands.
    private static func thinUUID(_ data: Data) -> String? {
        data.withUnsafeBytes { bytes -> String? in
            guard bytes.count >= 32, bytes.loadUnaligned(as: UInt32.self) == 0xFEED_FACF else { return nil }
            let count = bytes.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
            var offset = 32
            for _ in 0..<count {
                guard offset + 8 <= bytes.count else { return nil }
                let command = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let size = Int(bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                if command == 0x1B, offset + 24 <= bytes.count {
                    let raw = Array(bytes[(offset + 8)..<(offset + 24)])
                    return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                       raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])).uuidString
                }
                guard size > 0 else { return nil }
                offset += size
            }
            return nil
        }
    }

    /// Runs `body` with the build list locked against other hooks writing it at the same time.
    private static func withLock<T>(_ paths: HubPaths, _ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let descriptor = open(paths.hub.appending(path: "builds.lock").path, O_RDWR | O_CREAT, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        return body()
    }
}
#endif
