#if os(macOS)
import Darwin
import Foundation
import Network
import Synchronization

/// Checks the Mac operations needed to receive a report, in Redline's own process.
enum DoctorRuntime {
    static func projectCheck(_ project: URL, bundleIDs: [String], error: Error?) -> Doctor.Check {
        if let error {
            let nsError = error as NSError
            let denied =
                (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
                || (nsError.domain == NSPOSIXErrorDomain && [EPERM, EACCES].contains(Int32(nsError.code)))
            return Doctor.Check(
                status: .needsYou,
                name: "Project access",
                detail: denied
                    ? "Redline cannot read the project. Allow its file-access prompt if shown. For a protected folder, enable Redline in System Settings > Privacy & Security > Files & Folders; otherwise make the files readable by your account. Rerun doctor."
                    : "Redline could not read the project. Run doctor from your app's project folder, or pass --project <folder>."
            )
        }
        guard !bundleIDs.isEmpty else {
            return Doctor.Check(
                status: .needsYou,
                name: "App project",
                detail:
                    "No iOS app target was found here. Run doctor from your app's project folder, or pass --project <folder>."
            )
        }
        return Doctor.Check(
            status: .done,
            name: "Project access",
            detail: "Redline read this project's iOS app targets."
        )
    }

    /// Uses a temporary file in the actual inbox; no report is created or claimed.
    static func storageCheck(paths: HubPaths) -> Doctor.Check {
        let files = FileManager.default
        let existed = files.fileExists(atPath: paths.inbox.path)
        let probe = paths.inbox.appending(path: ".doctor-" + UUID().uuidString)
        defer {
            try? files.removeItem(at: probe)
            if !existed { rmdir(paths.inbox.path) }
        }
        do {
            try files.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
            try files.createDirectory(at: probe, withIntermediateDirectories: false)
            let file = probe.appending(path: "access")
            let content = Data(UUID().uuidString.utf8)
            try content.write(to: file, options: .withoutOverwriting)
            guard try Data(contentsOf: file) == content else { throw CocoaError(.fileReadCorruptFile) }
            try files.removeItem(at: probe)
            return Doctor.Check(
                status: .done,
                name: "Report storage",
                detail: "Redline wrote, read and removed a temporary file in its report inbox."
            )
        } catch {
            let outOfSpace =
                (error as NSError).domain == NSCocoaErrorDomain
                && (error as NSError).code == NSFileWriteOutOfSpaceError
            return Doctor.Check(
                status: .needsYou,
                name: "Report storage",
                detail: outOfSpace
                    ? "Free disk space on the Mac, then rerun doctor. Redline could not write to its report inbox."
                    : "Redline could not write, read or remove a file in its report inbox. Make its folder under ~/Library/Application Support/Redline writable by your account, allow a macOS file-access prompt if shown, then rerun doctor."
            )
        }
    }

    /// Starts a new instance of the Bonjour operation Redline uses, without contacting an app.
    static func networkCheck(timeout: TimeInterval = 4) -> Doctor.Check {
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: .tcp)
        let result = Mutex<NWBrowser.State?>(nil)
        let changed = DispatchSemaphore(value: 0)
        browser.stateUpdateHandler = { state in
            if case .setup = state { return }
            let first = result.withLock { value in
                guard value == nil else { return false }
                value = state
                return true
            }
            if first { changed.signal() }
        }
        browser.start(queue: DispatchQueue(label: "Redline.doctor.network", qos: .utility))
        _ = changed.wait(timeout: .now() + timeout)
        let state = result.withLock { $0 }
        browser.cancel()
        return networkCheck(state: state)
    }

    static func networkCheck(state: NWBrowser.State?) -> Doctor.Check {
        if case .ready? = state {
            return Doctor.Check(
                status: .done,
                name: "Local Network access",
                detail: "Redline registered its Bonjour browser for local discovery."
            )
        }
        if case .waiting(.dns(-65570))? = state {
            return Doctor.Check(
                status: .needsYou,
                name: "Local Network access",
                detail:
                    "macOS blocked Redline's Bonjour discovery. Allow its Local Network prompt, or enable Redline in System Settings > Privacy & Security > Local Network, then rerun doctor."
            )
        }
        return Doctor.Check(
            status: .needsYou,
            name: "Local Network access",
            detail:
                "Redline could not start local discovery. Connect the Mac to its local network, allow Redline's permission prompt if shown, then rerun doctor. This result does not establish a permission denial."
        )
    }

    static func destinationCheck(
        project: URL,
        bundleIDs: [String],
        agent: String,
        available: [Agent] = ChatDirectory.agents(),
        codexChats: () -> [CodexThreads.CodexThread] = { CodexThreads.recent(in: CodexThreads.newestDatabase()) },
        claudeChats: () -> [ClaudeSessions.Session] = { ClaudeSessions.openSessions() },
        codexHandshake: () -> CodexApp.Handshake = { CodexApp.checkHandshake(timeout: 2) },
        claudeConnection: (ClaudeSessions.Session) -> Bool = { session in
            guard let socket = UnixSocket.connect(path: session.socket) else { return false }
            close(socket)
            return true
        }
    ) -> Doctor.Check {
        let requested = Agent(rawValue: agent)
        let name = requested?.name ?? "Codex or Claude Code"
        guard available.contains(where: { requested == nil || $0 == requested }) else {
            return Doctor.Check(
                status: .needsYou,
                name: "Report destination",
                detail: "Install \(name) on this Mac, open a chat for this app project, then rerun doctor."
            )
        }
        // Match the app targets, as the report's chat picker does. A chat in another checkout
        // can receive this app's reports too; the worktree is a preference, not a requirement.
        let appIDs = Set(bundleIDs)
        var folders = [project.resolvingSymlinksInPath().standardizedFileURL.path: bundleIDs]
        func buildsApp(_ folder: String) -> Bool {
            let url = URL(filePath: folder).resolvingSymlinksInPath().standardizedFileURL
            let ids: [String]
            if let known = folders[url.path] {
                ids = known
            } else {
                ids = ProjectApps.bundleIDs(in: url)
                folders[url.path] = ids
            }
            return !appIDs.isDisjoint(with: ids)
        }
        var failures: [String] = []
        if requested != .claude, available.contains(.codex) {
            if codexChats().contains(where: { buildsApp($0.folder) }) {
                switch codexHandshake() {
                case .answered:
                    return Doctor.Check(
                        status: .done,
                        name: "Report destination",
                        detail: "Codex has a chat for this app and answered Redline's delivery handshake."
                    )
                case .notListening:
                    failures.append(
                        "Redline found a Codex chat for this app, but could not connect to the Codex app. Reopen Codex, then rerun doctor."
                    )
                case .notAnswering:
                    failures.append(
                        "Redline found a Codex chat for this app, but Codex did not answer the delivery handshake. Restart Codex, then rerun doctor. If this persists, update Redline and Codex."
                    )
                }
            }
        }
        if requested != .codex, available.contains(.claude) {
            var found = false
            for session in claudeChats() where buildsApp(session.folder) {
                found = true
                if claudeConnection(session) {
                    return Doctor.Check(
                        status: .done,
                        name: "Report destination",
                        detail: "A running Claude Code chat for this app accepts a connection from Redline."
                    )
                }
            }
            if found {
                failures.append(
                    "Redline found a running Claude Code chat for this app, but could not connect to its delivery socket. Restart that Claude Code chat, then rerun doctor."
                )
            }
        }
        return Doctor.Check(
            status: .needsYou,
            name: "Report destination",
            detail: failures.isEmpty
                ? "Redline could not find a chat for the app targets in \(project.path). Open a chat in \(name) for this app; another checkout of the same app also works. Then rerun doctor."
                : failures.joined(separator: " ")
        )
    }
}
#endif
