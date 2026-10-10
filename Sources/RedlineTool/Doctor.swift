#if os(macOS)
import Foundation

/// A setup checklist.
///
/// Observes configuration; never installs, migrates, starts or sends anything.
enum Doctor {
    enum Status: String, Sendable {
        case done = "Done"
        case needsYou = "Incomplete"
        case skipped = "Skipped"
        case check = "Check yourself"
    }

    struct Check: Sendable {
        var status: Status
        var name: String
        var detail: String
    }

    static func checks() -> [Check] {
        let environment = ProcessInfo.processInfo.environment
        let home = AgentSettings.homeDirectory(in: environment)
        var checks = toolchainChecks()
        checks += installationChecks(home: home, environment: environment, app: HubProcess.installedApp())
        let claude = AgentCommand.locate(.claude)
        let codex = AgentCommand.locate(.codex)
        let usesClaude = claude != nil || AgentSettings.isPresent(.claude) || AgentCommand.isClaudeAppInstalled()
        let usesCodex = codex != nil || AgentSettings.isPresent(.codex) || AgentCommand.isCodexAppInstalled()
        checks.append(
            Check(
                status: claude != nil || codex != nil ? .done : .needsYou,
                name: "Supported agent",
                detail: claude != nil || codex != nil
                    ? "Use Claude Code, Codex, or both."
                    : "Install Claude Code or Codex, then rerun the Redline installer. Only one is required."
            )
        )
        if usesClaude {
            let readiness = ClaudeCLI.checkReadiness(recheckingFailure: true)
            checks.append(claudeCheck(readiness))
            let configFolder = environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0) } ?? home
            checks.append(
                mcpCheck(
                    file: configFolder.appending(path: ".claude.json"),
                    command: home.appending(path: ".local/bin/redline")
                )
            )
            checks.append(
                Check(
                    status: .check,
                    name: "Claude Code chat",
                    detail:
                        "Start a new chat in your app's project after setup so it loads Redline's MCP server."
                )
            )
        } else {
            checks.append(
                Check(
                    status: .skipped,
                    name: "Claude Code",
                    detail: "Not installed or configured; optional when using Codex."
                )
            )
        }
        if usesCodex {
            checks.append(codexCommandCheck(command: codex))
            checks.append(
                codexHookCheck(
                    file: home.appending(path: ".codex/hooks.json"),
                    command: home.appending(path: ".local/bin/redline")
                )
            )
            checks.append(
                Check(
                    status: .check,
                    name: "Codex hook trust",
                    detail:
                        "Open /hooks in Codex and trust \"Report delivery\", then send a message in your project chat. Hook trust cannot be verified from hooks.json."
                )
            )
            checks.append(
                Check(
                    status: .check,
                    name: "Codex report delivery",
                    detail:
                        "Keep your chat open in the Codex app for immediate delivery. Without the app, the hook delivers waiting reports with your next message."
                )
            )
        } else {
            checks.append(
                Check(
                    status: .skipped,
                    name: "Codex",
                    detail: "Not installed or configured; optional when using Claude Code."
                )
            )
        }
        checks += manualChecks
        return checks
    }

    /// Installer requirements, checked with bounded commands that do not build or change Xcode.
    static func toolchainChecks(
        macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        run: (URL, [String]) -> String? = { CommandOutput.run($0, $1, timeout: 5) }
    ) -> [Check] {
        var checks = [
            Check(
                status: macOS.majorVersion >= 15 ? .done : .needsYou,
                name: "macOS",
                detail: macOS.majorVersion >= 15
                    ? "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion) (15 or later required)."
                    : "Update to macOS 15 or later in System Settings > General > Software Update."
            )
        ]
        func probe(_ command: String, _ arguments: [String]) -> String? {
            run(URL(filePath: "/usr/bin/\(command)"), arguments)
        }
        let xcode = probe("xcodebuild", ["-version"])
        let xcodeMajor = xcode?.split(separator: "\n").first.flatMap { line in
            line.hasPrefix("Xcode ") ? Int(line.dropFirst(6).split(separator: ".").first ?? "") : nil
        }
        let selected = xcodeMajor.map { $0 >= 26 } ?? false
        checks.append(
            Check(
                status: selected ? .done : .needsYou,
                name: "Xcode",
                detail: selected
                    ? "\(xcode?.split(separator: "\n").first ?? "Xcode") selected."
                    : "Install Xcode 26 or later and open it once. Select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer. Check DEVELOPER_DIR if set."
            )
        )
        if selected {
            for (name, arguments, fix) in [
                ("Xcode license", ["-license", "check"], "sudo xcodebuild -license accept"),
                ("Xcode components", ["-checkFirstLaunchStatus"], "sudo xcodebuild -runFirstLaunch"),
            ] {
                let passed = probe("xcodebuild", arguments) != nil
                checks.append(
                    Check(
                        status: passed ? .done : .needsYou,
                        name: name,
                        detail: passed
                            ? "Ready."
                            : "The check failed or timed out. Open Xcode; if unfinished, run: \(fix). Then rerun redline doctor."
                    )
                )
            }
        }
        let devicectl = probe("xcrun", ["--find", "devicectl"])
        checks.append(
            Check(
                status: devicectl != nil ? .done : .needsYou,
                name: "Device tools",
                detail: devicectl != nil
                    ? "devicectl is available."
                    : "Open the selected Xcode and finish installing its components, then rerun redline doctor."
            )
        )
        let swift = probe("xcrun", ["swift", "--version"])
        let numbers = swift?.firstMatch(of: /Swift version (\d+)\.(\d+)/)
        let current = numbers.map { [Int($0.1) ?? 0, Int($0.2) ?? 0] } ?? []
        let swiftReady = !current.isEmpty && !current.lexicographicallyPrecedes([6, 2])
        checks.append(
            Check(
                status: swiftReady ? .done : .needsYou,
                name: "Swift",
                detail: swiftReady
                    ? "\(current.map(String.init).joined(separator: ".")) (6.2 or later required to build Redline)."
                    : "Select Xcode 26 or later, which includes Swift 6.2 or later. Then rerun redline doctor."
            )
        )
        return checks
    }

    /// Reads the installed files and the hub's lock and saved status without creating any folders.
    static func installationChecks(home: URL, environment: [String: String], app: URL?) -> [Check] {
        let command = home.appending(path: ".local/bin/redline")
        let installed = FileManager.default.isExecutableFile(atPath: command.path)
        let firstOnPath = (environment["PATH"] ?? "").split(separator: ":").map { folder in
            URL(filePath: String(folder)).appending(path: "redline")
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        let onPath = firstOnPath?.resolvingSymlinksInPath() == command.resolvingSymlinksInPath()
        var checks = [
            Check(
                status: installed ? .done : .needsYou,
                name: "Redline command",
                detail: installed
                    ? "Installed in ~/.local/bin."
                    : "Run the Redline installer: npx agent-redline-ios (Node.js 18 or later), or use the curl command in README.md."
            ),
            Check(
                status: installed && onPath ? .done : .needsYou,
                name: "Terminal PATH",
                detail: installed && onPath
                    ? "This terminal finds the installed redline command."
                    : "After installing, add ~/.local/bin to PATH in your shell profile and open a new terminal. For zsh or bash: export PATH=\"$HOME/.local/bin:$PATH\". For fish: fish_add_path ~/.local/bin."
            ),
            Check(
                status: app != nil ? .done : .needsYou,
                name: "Redline app",
                detail: app != nil
                    ? "Installed." : "Rerun the Redline installer to build and install ~/Applications/Redline.app."
            ),
        ]
        let loginItem = home.appending(path: "Library/LaunchAgents/com.agentredline.hub.plist")
        checks.append(
            Check(
                status: .check,
                name: "Open at login",
                detail: FileManager.default.fileExists(atPath: loginItem.path)
                    ? "A login item is installed. Check System Settings > General > Login Items & Extensions if Redline does not start at login."
                    : "No login item found. Optional: rerun the installer to start Redline at login, or open Redline yourself."
            )
        )
        let paths = HubPaths(root: home.appending(path: "Library/Application Support/Redline"))
        if let pid = HubProcess.running(paths) {
            let status = (try? Data(contentsOf: paths.status)).flatMap {
                try? HubPaths.decoder.decode(HubStatus.self, from: $0)
            }
            checks.append(
                Check(
                    status: status?.pid == pid ? .done : .needsYou,
                    name: "Redline hub",
                    detail: status?.pid == pid
                        ? "Running."
                        : "A hub holds the lock, but its status is missing, unreadable or stale. Wait a moment and rerun doctor; if it persists, inspect ~/Library/Application Support/Redline/hub/hub.log."
                )
            )
            if status?.pid == pid, let status {
                checks.append(
                    Check(
                        status: status.hosts.isEmpty ? .needsYou : .done,
                        name: "Hub network address",
                        detail: status.hosts.isEmpty
                            ? "The hub reports no network address. Connect the Mac to your local network, then reopen Redline."
                            : "The hub has a saved network address. This does not verify permissions or connectivity from the app."
                    )
                )
            }
        } else {
            checks.append(
                Check(
                    status: .needsYou,
                    name: "Redline hub",
                    detail:
                        "Not running. After installing, run: open -b com.agentredline.hub. If startup fails, inspect ~/Library/Application Support/Redline/hub/hub.log."
                )
            )
        }
        return checks
    }

    static func claudeCheck(_ readiness: ClaudeCLI.Readiness) -> Check {
        switch readiness {
        case .ready:
            Check(
                status: .done,
                name: "Claude Code command",
                detail: "Runs, is signed in, and meets the installed Claude app's version requirement."
            )
        case .doesNotRun:
            Check(
                status: .needsYou,
                name: "Claude Code command",
                detail:
                    "The check failed or timed out. Run claude --version and claude auth status in Terminal, fix the error, then rerun redline doctor."
            )
        case .needs(.signIn):
            Check(
                status: .needsYou,
                name: "Claude Code command",
                detail:
                    "Sign-in could not be verified. Run claude auth status in Terminal; if signed out, run claude auth login. Then rerun redline doctor."
            )
        case .needs(let need):
            Check(status: .needsYou, name: "Claude Code command", detail: ClaudeCLI.instruction(for: need))
        }
    }

    /// Checks the user-scope entry the installer owns, without starting an MCP server.
    static func mcpCheck(file: URL, command: URL) -> Check {
        do {
            let settings = try json(at: file)
            let entry = (settings["mcpServers"] as? [String: Any])?["redline"] as? [String: Any]
            if entry?["command"] as? String == command.path, entry?["args"] as? [String] == ["mcp"],
                entry?["type"] == nil || entry?["type"] as? String == "stdio"
            {
                return Check(
                    status: .done,
                    name: "Claude Code MCP",
                    detail: "The user-scope Redline entry runs the installed command."
                )
            }
            return Check(
                status: .needsYou,
                name: "Claude Code MCP",
                detail: entry == nil
                    ? "No user-scope Redline entry found. Rerun the installer to add it."
                    : "The user-scope redline entry does not match the installed command. Check claude mcp list for conflicts, then rerun the installer. Doctor does not replace entries."
            )
        } catch {
            return Check(
                status: .needsYou,
                name: "Claude Code MCP",
                detail:
                    "The user configuration could not be read as a JSON object. Repair it before rerunning the installer. Doctor does not print its contents."
            )
        }
    }

    /// Probes the CLI's own sign-in without starting a chat or printing account information.
    static func codexCommandCheck(
        command: URL?,
        run: (URL, [String]) -> String? = { CommandOutput.run($0, $1, timeout: 5) }
    ) -> Check {
        guard let command else {
            return Check(
                status: .needsYou,
                name: "Codex command",
                detail: "Install or update Codex so its command is available, then rerun the Redline installer."
            )
        }
        guard run(command, ["--version"]) != nil else {
            return Check(
                status: .needsYou,
                name: "Codex command",
                detail:
                    "The command failed or timed out. Run codex --version in Terminal, fix the error, then rerun redline doctor."
            )
        }
        guard run(command, ["login", "status"]) != nil else {
            return Check(
                status: .needsYou,
                name: "Codex command",
                detail:
                    "Sign-in could not be verified. Run codex login status in Terminal; if signed out, run codex login. Then rerun redline doctor."
            )
        }
        return Check(
            status: .done,
            name: "Codex command",
            detail: "Runs and its CLI sign-in check succeeds. Check the desktop app's sign-in separately if using it."
        )
    }

    /// Looks for the exact active prompt hook, not just its display name or an old Redline hook.
    static func codexHookCheck(file: URL, command: URL) -> Check {
        do {
            let settings = try json(at: file)
            let events = settings["hooks"] as? [String: Any] ?? [:]
            let groups = events["UserPromptSubmit"] as? [[String: Any]] ?? []
            let expected =
                AgentSettings.hooks(.codex, executable: command.path).first?.hooks.first?["command"] as? String
            let found = groups.contains { group in
                group["matcher"] == nil
                    && (group["hooks"] as? [[String: Any]] ?? []).contains { hook in
                        hook["type"] as? String == "command" && hook["command"] as? String == expected
                            && hook["statusMessage"] as? String == "Report delivery"
                    }
            }
            return Check(
                status: found ? .done : .needsYou,
                name: "Codex hook",
                detail: found
                    ? "The Report delivery command is configured. Trust must still be checked in Codex."
                    : "The installed Redline prompt hook is missing or differs. Run: redline setup. Then trust Report delivery in /hooks."
            )
        } catch {
            return Check(
                status: .needsYou,
                name: "Codex hook",
                detail:
                    "~/.codex/hooks.json could not be read as a JSON object. Repair it, then run redline setup. Doctor leaves it untouched."
            )
        }
    }

    private static func json(at file: URL) throws -> [String: Any] {
        guard let data = try StoredFile.read(file) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    static let manualChecks = [
        Check(
            status: .check,
            name: "Mac permissions",
            detail:
                "Open Redline and allow Local Network when asked. If denied, enable Redline in System Settings > Privacy & Security > Local Network. Allow Documents access if projects are there. Notifications are optional. Doctor does not request or verify these permissions."
        ),
        Check(
            status: .check,
            name: "App integration",
            detail:
                "Add the Redline library to your iOS 18+ SwiftUI app target and .redline() to its root view. For a physical device, select your development team in Xcode. Build and run Debug; Release builds have no Redline overlay. Check this in your project."
        ),
        Check(
            status: .check,
            name: "Physical iPhone (skip for simulator)",
            detail:
                "Pair with Xcode and accept the trust prompts. In Settings > Privacy & Security, enable Developer Mode, restart, and confirm Enable. Keep the Mac and iPhone on the same local network. Allow your app's Local Network prompt; if denied, enable the app in Settings > Privacy & Security > Local Network. After the first install, quit and reopen Redline to rescan."
        ),
        Check(
            status: .check,
            name: "First report",
            detail:
                "Start a project chat and run your Debug app. Tap Redline, select an element, add a note and Send to that chat. Confirm the note and snapshot arrive. A setup checklist alone does not prove delivery."
        ),
    ]

    static func exitCode(for checks: [Check]) -> Int32 {
        checks.contains { $0.status == .needsYou } ? 1 : 0
    }

    static func usesColor(isTerminal: Bool, environment: [String: String]) -> Bool {
        isTerminal && environment["TERM"] != "dumb" && environment["NO_COLOR"]?.isEmpty != false
    }

    static func text(for checks: [Check], version: String, color: Bool = false) -> String {
        let automatic = checks.filter { $0.status != .check }
        let manual = checks.filter { $0.status == .check }
        func lines(_ checks: [Check]) -> String {
            checks.map { check in
                let marker: String
                let ansi: String
                switch check.status {
                case .done:
                    marker = "✓ "
                    ansi = "\u{1B}[32m"
                case .needsYou:
                    marker = "✗ "
                    ansi = "\u{1B}[31m"
                case .skipped, .check:
                    marker = ""
                    ansi = ""
                }
                let heading = "\(marker)[\(check.status.rawValue)] \(check.name)"
                let styled = color && !ansi.isEmpty ? "\(ansi)\(heading)\u{1B}[0m" : heading
                return "\(styled)\n  \(check.detail.replacing("\n", with: "\n  "))"
            }.joined(separator: "\n\n")
        }
        let missing = checks.filter { $0.status == .needsYou }.count
        let summary =
            missing == 0
            ? "No missing steps found by the automatic checks."
            : "\(missing) automatic \(missing == 1 ? "check needs" : "checks need") your attention."
        return
            "Redline doctor \(version)\nRead-only setup checks\n\n\(lines(automatic))\n\nCheck yourself\n\n\(lines(manual))\n\n\(summary) Complete the manual checks and confirm your first report arrives."
    }
}
#endif
