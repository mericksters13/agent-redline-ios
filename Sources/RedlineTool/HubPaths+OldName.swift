#if os(macOS)
import Darwin
import Foundation

// MARK: - The folder from before the rename

extension HubPaths {
    /// What `moveFromOldName(to:)` did.
    enum OldFolderMove: Equatable, Sendable {
        /// Nothing had to move, or it moved with no hub of the earlier version running.
        case done
        /// It moved once the earlier version's hub stopped. This version's hub has to take over,
        /// watching the apps that hub was given on the command line.
        case stoppedHub(fixedApps: [String])
        /// It couldn't move yet, for the reason given. Nothing may use this version's folder until it
        /// has, or what the earlier version kept would stay behind for good.
        case blocked(String)
    }

    /// The name the folder had before the rename.
    static let oldName = "iOSAgenticDebuggingKit"

    /// Moves the folder kept under the old name to `paths`, so reports, chats and tokens carry over.
    ///
    /// Only while nothing is at `paths` yet.
    ///
    /// A hub of the earlier version that is still running knows only the old folder, so it's asked
    /// to stop first. If it hasn't said within 5 seconds which apps it watches, or doesn't stop
    /// within 3 more, such as while it hands a report over, nothing moves and the result says why.
    /// Only a process holding the old `hub.pid` lock is that hub, so a pid left by a hub that
    /// crashed, and since reused, is never signaled.
    ///
    /// The old name is left as a link to the new folder: an MCP server of the earlier version still
    /// serving an open chat knows only the old folder, and through the link it keeps reading the
    /// same inbox and chat records as this version's hub.
    ///
    /// Parks the main thread for up to 8 seconds while an earlier hub stops; called once, as the
    /// command starts.
    @MainActor
    static func moveFromOldName(to paths: HubPaths) -> OldFolderMove {
        let old = HubPaths(
            root: paths.root.deletingLastPathComponent().appending(path: oldName, directoryHint: .isDirectory)
        )
        let files = FileManager.default
        guard files.fileExists(atPath: old.root.path), !files.fileExists(atPath: paths.root.path) else {
            return .done
        }
        var stoppedHub = false
        var fixedApps: [String] = []
        if let running = HubProcess.running(old), running != getpid() {
            // Read before it stops: the apps it was given on the command line. A hub saves its
            // status, with those apps, as it starts; give one starting now a moment. One that
            // doesn't say which apps it watches is left running, as the app's takeover leaves
            // one, so its apps aren't silently dropped.
            var status = savedStatus(old)
            for _ in 0..<50 where status?.pid != running && HubProcess.running(old) == running {
                usleep(100_000)
                status = savedStatus(old)
            }
            if HubProcess.running(old) == running {
                guard let status, status.pid == running else {
                    return .blocked(
                        "The hub of an earlier version (pid \(running)) didn't say which apps it watches, so it was left running and its folder can't move to Redline's yet. Run redline again in a moment, or stop that hub first."
                    )
                }
                // A hub from before fixedApps was saved lists them only among all its apps.
                fixedApps = status.fixedApps ?? status.apps
                kill(running, SIGTERM)
            }
            for _ in 0..<30 where HubProcess.running(old) != nil { usleep(100_000) }
            guard HubProcess.running(old) == nil else {
                return .blocked(
                    "The hub of an earlier version (pid \(running)) is still running, so its folder can't move to Redline's yet. It stops on its own once the reports it's handing over reach their chats; run redline again then."
                )
            }
            stoppedHub = true
        }
        do {
            try files.moveItem(at: old.root, to: paths.root)
        } catch {
            return .blocked("Couldn't move \(old.root.path) to \(paths.root.path): \(error.localizedDescription)")
        }
        do {
            try files.createSymbolicLink(at: old.root, withDestinationURL: paths.root)
        } catch {
            printError("Couldn't leave a link to \(paths.root.path) at \(old.root.path): \(error.localizedDescription)")
        }
        return stoppedHub ? .stoppedHub(fixedApps: fixedApps) : .done
    }
}
#endif
