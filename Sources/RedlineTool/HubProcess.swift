#if os(macOS)
import AppKit
import Darwin

/// Starting the hub from a chat, so nothing has to be started by hand.
enum HubProcess {
    /// Takes the hub's lock: `hub.pid`, held with an exclusive `flock` for as long as the returned
    /// descriptor is open, with this process's pid written in it.
    ///
    /// The kernel releases the lock however the process ends, so a file left by a hub that crashed
    /// or was killed never names a running hub. Nil when another hub holds the lock or the file
    /// can't be opened.
    static func lock(_ paths: HubPaths) -> Int32? {
        // Close-on-exec, so agents and git started by the hub don't hold the lock after it ends.
        let descriptor = open(paths.pid.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let pid = Data("\(getpid())".utf8)
        ftruncate(descriptor, 0)
        _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        return descriptor
    }

    /// The pid of a hub that's running, if any: one that holds the lock on `hub.pid`.
    static func running(_ paths: HubPaths) -> Int32? {
        let descriptor = open(paths.pid.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // Nobody holds the lock: whatever pid the file names, that hub is gone.
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return nil }
        return Int32(
            String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The menu bar app's bundle identifier, as scripts/build-hub-app.sh sets it.
    static let appBundleID = "com.agentredline.hub"

    /// The menu bar app, which is the hub, when it's installed: in ~/Applications, where
    /// scripts/build-hub-app.sh puts it by default, or wherever else Launch Services knows it by its
    /// identifier, such as /Applications.
    ///
    /// Checks the disk.
    static func installedApp() -> URL? {
        let home = AgentSettings.homeDirectory().appending(path: "Applications/Redline.app")
        if FileManager.default.fileExists(atPath: home.path) { return home }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Starts the hub: the menu bar app when it's installed, else this command in its own
    /// session, so it keeps running after the chat that started it closes, with nothing attached
    /// to the chat's input and output.
    static func startIfNeeded(_ paths: HubPaths) {
        guard running(paths) == nil else { return }
        if let app = installedApp() {
            let open = Process()
            open.executableURL = URL(filePath: "/usr/bin/open")
            open.arguments = ["-g", app.path]
            do {
                try open.run()
            } catch {
                printError("Couldn't open \(app.path): \(error.localizedDescription)")
            }
            return
        }
        guard let executable = Bundle.main.executablePath else {
            printError("Couldn't start the hub: this command's own path is unknown")
            return
        }
        func failed(_ step: String, _ status: Int32) -> Bool {
            guard status != 0 else { return false }
            printError("Couldn't start the hub (\(step)): \(String(cString: strerror(status)))")
            return true
        }
        var attributes: posix_spawnattr_t?
        guard !failed("attributes", posix_spawnattr_init(&attributes)) else { return }
        defer { posix_spawnattr_destroy(&attributes) }
        guard !failed("new session", posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))) else { return }
        var files: posix_spawn_file_actions_t?
        guard !failed("file actions", posix_spawn_file_actions_init(&files)) else { return }
        defer { posix_spawn_file_actions_destroy(&files) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let mode = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            guard !failed("/dev/null", posix_spawn_file_actions_addopen(&files, descriptor, "/dev/null", mode, 0))
            else { return }
        }
        var pid: pid_t = 0
        let arguments = [executable, "hub"]
        var argv = arguments.map { strdup($0) } + [nil]
        defer {
            for argument in argv { free(argument) }
        }
        _ = failed("spawn", posix_spawn(&pid, executable, &files, &attributes, &argv, environ))
    }
}
#endif
