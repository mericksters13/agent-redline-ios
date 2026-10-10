#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RedlineTool

struct DoctorTests {
    private let temporary = TemporaryFolder("DoctorTests")

    private func write(_ contents: String, to file: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
    }

    @Test func toolchainFailuresGiveFixesWithoutRunningThem() {
        var calls: [[String]] = []
        let checks = Doctor.toolchainChecks(
            macOS: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        ) { url, arguments in
            calls.append([url.path] + arguments)
            return nil
        }
        #expect(checks.allSatisfy { $0.status == .needsYou })
        #expect(checks.first?.detail.contains("Software Update") == true)
        #expect(checks.first { $0.name == "Xcode" }?.detail.contains("sudo xcode-select") == true)
        #expect(
            calls == [
                ["/usr/bin/xcodebuild", "-version"],
                ["/usr/bin/xcrun", "--find", "devicectl"],
                ["/usr/bin/xcrun", "swift", "--version"],
            ]
        )
    }

    @Test func theOldestToolchainPassesAndUnfinishedComponentsNeedAction() {
        let checks = Doctor.toolchainChecks { url, arguments in
            switch arguments {
            case ["-version"]: "Xcode 26.0.1\nBuild version 17A400"
            case ["-license", "check"]: ""
            case ["-checkFirstLaunchStatus"]: nil
            case ["--find", "devicectl"]: "/tool/devicectl"
            case ["swift", "--version"]: "Apple Swift version 6.2 (swiftlang)"
            default: nil
            }
        }
        #expect(checks.first { $0.name == "Xcode" }?.status == .done)
        #expect(checks.first { $0.name == "Swift" }?.status == .done)
        #expect(
            checks.first { $0.name == "Xcode components" }?.detail.contains("sudo xcodebuild -runFirstLaunch") == true
        )
        #expect(Doctor.exitCode(for: checks) == 1)
    }

    @Test func aShadowedCommandAndStoppedHubAreNotReportedAsReady() throws {
        let home = temporary.url
        let command = home.appending(path: ".local/bin/redline")
        let other = home.appending(path: "other/redline")
        try write("#!/bin/sh\nexit 0", to: command, executable: true)
        try write("#!/bin/sh\nexit 0", to: other, executable: true)
        let checks = Doctor.installationChecks(
            home: home,
            environment: [
                "PATH": "\(other.deletingLastPathComponent().path):\(command.deletingLastPathComponent().path)"
            ],
            app: nil
        )
        #expect(checks.first { $0.name == "Redline command" }?.status == .done)
        #expect(checks.first { $0.name == "Terminal PATH" }?.status == .needsYou)
        #expect(checks.first { $0.name == "Redline hub" }?.detail.contains("open -b com.agentredline.hub") == true)
        #expect(
            !FileManager.default.fileExists(atPath: home.appending(path: "Library/Application Support/Redline").path)
        )
    }

    @Test func aLockedHubWithStaleStatusNeedsAttentionAndStaysRunning() throws {
        let home = temporary.url
        let paths = HubPaths(root: home.appending(path: "Library/Application Support/Redline"))
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let lock = try #require(HubProcess.lock(paths))
        defer { close(lock) }
        let stale = HubStatus(
            pid: -1,
            startedAt: .now,
            apps: [],
            hosts: ["127.0.0.1"],
            port: 47361,
            phones: [],
            simulatorContainers: 0
        )
        try HubPaths.encoder.encode(stale).write(to: paths.status)
        let before = try Data(contentsOf: paths.status)
        let checks = Doctor.installationChecks(home: home, environment: [:], app: nil)
        #expect(checks.first { $0.name == "Redline hub" }?.status == .needsYou)
        #expect(HubProcess.running(paths) == getpid())
        #expect(try Data(contentsOf: paths.status) == before)
    }

    @Test func codexRequiresTheCurrentPromptCommandRatherThanAnOldHookOrDisplayName() throws {
        let file = temporary.url.appending(path: "hooks.json")
        let command = temporary.url.appending(path: "redline")
        var settings = AgentSettings.adding(.codex, to: [:], executable: command.path)
        try write(try sortedJSON(settings), to: file)
        let before = try Data(contentsOf: file)
        #expect(Doctor.codexHookCheck(file: file, command: command).status == .done)
        #expect(try Data(contentsOf: file) == before)
        settings = AgentSettings.adding(
            .codex,
            to: [:],
            executable: command.deletingLastPathComponent().appending(path: "agentic-debugging").path
        )
        try write(try sortedJSON(settings), to: file)
        #expect(Doctor.codexHookCheck(file: file, command: command).status == .needsYou)
        try write("{\"hooks\":{\"Stop\":[{\"hooks\":[{\"statusMessage\":\"Report delivery\"}]}]}}", to: file)
        #expect(Doctor.codexHookCheck(file: file, command: command).status == .needsYou)
    }

    @Test func malformedSettingsAreNotTreatedAsMissingAndDoNotLeakTheirContents() throws {
        let file = temporary.url.appending(path: "settings.json")
        let secret = "secret-value-that-must-not-be-printed"
        try write("{broken \(secret)", to: file)
        let before = try Data(contentsOf: file)
        let checks = [Doctor.mcpCheck(file: file, command: file), Doctor.codexHookCheck(file: file, command: file)]
        #expect(checks.allSatisfy { $0.status == .needsYou })
        #expect(checks.allSatisfy { $0.detail.contains("JSON object") })
        #expect(!Doctor.text(for: checks, version: "test").contains(secret))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func mcpChecksItsCommandAndArgumentsAndNeverReplacesAConflict() throws {
        let file = temporary.url.appending(path: ".claude.json")
        let command = temporary.url.appending(path: "redline")
        #expect(Doctor.mcpCheck(file: file, command: command).status == .needsYou)
        try write(try sortedJSON(["mcpServers": ["redline": ["command": command.path, "args": ["mcp"]]]]), to: file)
        #expect(Doctor.mcpCheck(file: file, command: command).status == .done)
        try write(try sortedJSON(["mcpServers": ["redline": ["command": command.path, "args": ["remove"]]]]), to: file)
        let before = try Data(contentsOf: file)
        #expect(Doctor.mcpCheck(file: file, command: command).status == .needsYou)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func agentSignInFailuresGiveCommandsAndNoAuthOutput() {
        #expect(Doctor.claudeCheck(.needs(.signIn)).detail.contains("claude auth login"))
        var calls: [[String]] = []
        let check = Doctor.codexCommandCheck(command: URL(filePath: "/codex")) { _, arguments in
            calls.append(arguments)
            return arguments == ["--version"] ? "codex-cli test" : nil
        }
        #expect(check.status == .needsYou)
        #expect(check.detail.contains("codex login"))
        #expect(calls == [["--version"], ["login", "status"]])
    }

    @Test func passingAutomaticChecksStillRequireManualDeliveryVerification() {
        let checks = [Doctor.Check(status: .done, name: "Setup", detail: "Ready.")] + Doctor.manualChecks
        #expect(Doctor.exitCode(for: checks) == 0)
        let text = Doctor.text(for: checks, version: "test")
        #expect(text.contains("Check yourself"))
        #expect(text.contains("Developer Mode, restart, and confirm Enable"))
        #expect(text.contains("does not request or verify"))
        #expect(text.contains("confirm your first report arrives"))
    }

    @Test func plainOutputKeepsStatusMarksAndDoesNotColorUnverifiedChecks() {
        let checks = [
            Doctor.Check(status: .done, name: "Xcode", detail: "Ready."),
            Doctor.Check(status: .needsYou, name: "Hub", detail: "Open Redline."),
            Doctor.Check(status: .skipped, name: "Optional agent", detail: "Not needed."),
            Doctor.Check(status: .check, name: "Permission", detail: "Not verified."),
        ]
        let plain = Doctor.text(for: checks, version: "test")
        #expect(plain.contains("✓ [Done] Xcode"))
        #expect(plain.contains("✗ [Incomplete] Hub"))
        #expect(!plain.contains("\u{1B}"))

        let colored = Doctor.text(for: checks, version: "test", color: true)
        #expect(colored.contains("\u{1B}[32m✓ [Done] Xcode\u{1B}[0m\n  Ready."))
        #expect(colored.contains("\u{1B}[31m✗ [Incomplete] Hub\u{1B}[0m\n  Open Redline."))
        #expect(!colored.contains("\u{1B}[32m[Skipped]"))
        #expect(!colored.contains("\u{1B}[31m[Check yourself]"))
        #expect(
            colored.replacing("\u{1B}[32m", with: "").replacing("\u{1B}[31m", with: "")
                .replacing("\u{1B}[0m", with: "") == plain
        )
    }

    @Test func colorRespectsRedirectionAndTerminalPreferences() {
        #expect(Doctor.usesColor(isTerminal: true, environment: ["TERM": "xterm-256color"]))
        #expect(!Doctor.usesColor(isTerminal: false, environment: ["TERM": "xterm-256color"]))
        #expect(!Doctor.usesColor(isTerminal: true, environment: ["TERM": "dumb"]))
        #expect(!Doctor.usesColor(isTerminal: true, environment: ["NO_COLOR": "1"]))
        #expect(Doctor.usesColor(isTerminal: true, environment: ["NO_COLOR": ""]))
    }

    @Test func doctorRunsBeforeOldDataMigrationAndLeavesSettingsUntouched() async throws {
        let home = temporary.url
        let old = home.appending(path: "Library/Application Support/Agentic Debugging/marker")
        try write("old data", to: old)
        let hooks = home.appending(path: ".codex/hooks.json")
        try write("{broken", to: hooks)
        let before = try Data(contentsOf: hooks)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = root.appending(path: ".build/debug/redline")
        // Use the test build's executable, never the user's installed Redline.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CLAUDE_CONFIG_DIR"] = home.path
        let fixtureEnvironment = environment
        let output = await offPool {
            CommandOutput.run(
                URL(filePath: "/bin/sh"),
                [
                    "-c", "\"$1\" doctor; result=$?; printf '\\nDoctor exit: %s\\n' \"$result\"", "doctor-test",
                    executable.path,
                ],
                timeout: 90,
                environment: fixtureEnvironment
            )
        }
        #expect(output?.contains("Redline doctor") == true)
        #expect(output?.contains("Doctor exit: 1") == true)
        #expect(output?.contains("\u{1B}") == false)
        #expect(try String(contentsOf: old, encoding: .utf8) == "old data")
        #expect(try Data(contentsOf: hooks) == before)
        #expect(
            !FileManager.default.fileExists(atPath: home.appending(path: "Library/Application Support/Redline").path)
        )
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Applications/Redline.app").path))
    }
}
#endif
