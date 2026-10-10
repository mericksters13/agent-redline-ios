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

    static func destinationCheck(project: URL, agent: String, available: [Agent] = ChatDirectory.agents())
        -> Doctor.Check
    {
        let requested = Agent(rawValue: agent)
        let name = requested?.name ?? "Codex or Claude Code"
        guard available.contains(where: { requested == nil || $0 == requested }) else {
            return Doctor.Check(
                status: .needsYou,
                name: "Report destination",
                detail: "Install \(name) on this Mac, open a chat for this app project, then rerun doctor."
            )
        }
        let root = Worktree.root(of: project.path)
        if requested != .claude, available.contains(.codex) {
            let chats = CodexThreads.recent(in: CodexThreads.newestDatabase())
                .filter { Worktree.root(of: $0.folder) == root }
            if !chats.isEmpty, CodexApp.checkHandshake(timeout: 2) == .answered {
                return Doctor.Check(
                    status: .done,
                    name: "Report destination",
                    detail: "Codex has a chat for this project and answered Redline's delivery handshake."
                )
            }
        }
        if requested != .codex, available.contains(.claude) {
            for session in ClaudeSessions.openSessions() where Worktree.root(of: session.folder) == root {
                if let socket = UnixSocket.connect(path: session.socket) {
                    close(socket)
                    return Doctor.Check(
                        status: .done,
                        name: "Report destination",
                        detail: "A running Claude Code chat for this project accepts a connection from Redline."
                    )
                }
            }
        }
        return Doctor.Check(
            status: .needsYou,
            name: "Report destination",
            detail: "Open a chat in \(name) for this app project. Keep it open, then rerun doctor."
        )
    }
}
#endif
