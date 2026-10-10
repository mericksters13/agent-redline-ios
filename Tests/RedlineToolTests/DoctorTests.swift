#if os(macOS)
import Darwin
import Foundation
import Network
import Testing
@testable import RedlineTool

struct DoctorTests {
    private let temporary = TemporaryFolder("DoctorTests")

    private func write(_ contents: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    @Test func optionsSelectOneProjectAndAgent() throws {
        let options = try #require(Doctor.options(["--project", "/tmp/App", "--agent", "codex"][...]))
        #expect(options.project.path == "/tmp/App")
        #expect(options.agent == "codex")
        #expect(Doctor.options([])?.agent == "auto")
        #expect(Doctor.options(["--agent", "other"][...]) == nil)
        #expect(Doctor.options(["--project"][...]) == nil)
        #expect(Doctor.options(["--device", "phone"][...]) == nil)
    }

    @Test func missingOrStoppedAppGivesAnActionWithoutInstallingOrStartingIt() {
        let home = temporary.url
        let missing = Doctor.installationChecks(home: home, app: nil)
        #expect(missing.count == 1)
        #expect(missing.first?.status == .needsYou)
        #expect(missing.first?.detail.contains("npx agent-redline-ios") == true)
        let stopped = Doctor.installationChecks(home: home, app: home.appending(path: "Redline.app"))
        #expect(stopped.first?.detail.contains("open -b com.agentredline.hub") == true)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Library").path))
    }

    @Test func aLockedHubWithStaleStatusNeedsAttentionAndStaysRunning() throws {
        let home = temporary.url
        let paths = HubPaths(root: home.appending(path: "Library/Application Support/Redline"))
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let lock = try #require(HubProcess.lock(paths))
        defer { close(lock) }
        try saveStatus(pid: -1, paths: paths)
        let before = try Data(contentsOf: paths.status)
        let checks = Doctor.installationChecks(home: home, app: nil)
        #expect(checks.first?.status == .needsYou)
        #expect(HubProcess.running(paths) == getpid())
        #expect(try Data(contentsOf: paths.status) == before)
    }

    private func saveStatus(pid: Int32, paths: HubPaths) throws {
        let status = HubStatus(
            pid: pid,
            startedAt: .now,
            apps: [],
            hosts: [],
            port: 47361,
            phones: [],
            simulatorContainers: 0
        )
        try HubPaths.encoder.encode(status).write(to: paths.status)
    }

    @Test(arguments: ["stale request", "wrong process", "terminal hub", "old app", "passed"])
    func runtimeRepliesMustComeFromThisRequestAndTheRunningMacApp(_ scenario: String) async throws {
        // Short enough for Darwin's Unix socket path limit.
        let home = URL(filePath: "/tmp/rld-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = HubPaths(root: home.appending(path: "Library/Application Support/Redline"))
        try FileManager.default.createDirectory(at: paths.hub, withIntermediateDirectories: true)
        let lock = try #require(HubProcess.lock(paths))
        defer { close(lock) }
        try saveStatus(pid: getpid(), paths: paths)
        let server = try #require(
            DoctorConnection.start(paths: paths) { request in
                DoctorConnection.Reply(
                    id: scenario == "stale request" ? UUID() : request.id,
                    pid: scenario == "wrong process" ? -1 : getpid(),
                    isMacApp: scenario != "terminal hub",
                    checks: scenario == "old app"
                        ? [] : [Doctor.Check(status: .done, name: "Project access", detail: "Read.")]
                )
            }
        )
        defer { server.stop() }
        let checks = await offPool { Doctor.checks(project: home, home: home, app: nil) }
        #expect(Doctor.exitCode(for: checks) == (scenario == "passed" ? 0 : 1))
        #expect(checks.contains { $0.name == "Project access" } == (scenario == "passed"))
        let text = Doctor.text(for: checks, version: "test")
        #expect(!text.contains("Check yourself"))
        #expect(!text.contains("Developer Mode"))
        #expect(!text.contains("pair"))
        let permissions = try FileManager.default.attributesOfItem(
            atPath: paths.hub.appending(path: "doctor/socket").path
        )
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unknownNetworkStateIsIncompleteAndNotCalledDenied() {
        for state: NWBrowser.State? in [
            nil, .setup, .cancelled, .failed(.posix(.ENETDOWN)), .waiting(.posix(.ENETDOWN)),
        ] {
            let check = DoctorRuntime.networkCheck(state: state)
            #expect(check.status == .needsYou)
            #expect(check.detail.contains("does not establish a permission denial"))
        }
        let denied = DoctorRuntime.networkCheck(state: .waiting(.dns(-65570)))
        #expect(denied.status == .needsYou)
        #expect(denied.detail.contains("System Settings > Privacy & Security > Local Network"))
        #expect(DoctorRuntime.networkCheck(state: .ready).status == .done)
    }

    @Test func unreadableProjectIsIncompleteEvenWhenSomeTargetsWereFound() {
        let denied = CocoaError(.fileReadNoPermission)
        let check = DoctorRuntime.projectCheck(temporary.url, bundleIDs: ["com.example.app"], error: denied)
        #expect(check.status == .needsYou)
        #expect(check.detail.contains("Files & Folders"))
        #expect(DoctorRuntime.projectCheck(temporary.url, bundleIDs: [], error: nil).status == .needsYou)
        #expect(DoctorRuntime.projectCheck(temporary.url, bundleIDs: ["com.example.app"], error: nil).status == .done)
    }

    @Test func missingBuildSettingsAreReportedWithoutChangingTheFiles() throws {
        let file = temporary.url.appending(path: "App.xcconfig")
        try write("#include \"Required.xcconfig\"\nPRODUCT_BUNDLE_IDENTIFIER = com.example.app", to: file)
        var errors: [Error] = []
        let settings = ProjectApps.xcconfigSettings(at: file, onReadError: { errors.append($0) })
        #expect(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "com.example.app")
        #expect(errors.count == 1)
        try write("#include? \"Optional.xcconfig\"", to: file)
        errors.removeAll()
        _ = ProjectApps.xcconfigSettings(at: file, onReadError: { errors.append($0) })
        #expect(errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporary.url.appending(path: "Required.xcconfig").path))
    }

    @Test func storageProbeCleansUpAndPreservesReports() throws {
        let paths = HubPaths(root: temporary.url)
        let report = paths.inbox.appending(path: "com.example.app/report/marker")
        try write("existing report", to: report)
        #expect(DoctorRuntime.storageCheck(paths: paths).status == .done)
        #expect(try String(contentsOf: report, encoding: .utf8) == "existing report")
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path) == ["com.example.app"])
    }

    @Test func storageFailureDoesNotCreateAReportOrOverwriteTheBlockingFile() throws {
        let paths = HubPaths(root: temporary.url)
        try write("keep", to: paths.inbox)
        let check = DoctorRuntime.storageCheck(paths: paths)
        #expect(check.status == .needsYou)
        #expect(try String(contentsOf: paths.inbox, encoding: .utf8) == "keep")
    }

    @Test func outputColorsOnlyCheckedStatesAndDescribesMacScope() {
        let checks = [
            Doctor.Check(status: .done, name: "Project access", detail: "Read."),
            Doctor.Check(status: .needsYou, name: "Local Network access", detail: "Allow Redline."),
        ]
        let plain = Doctor.text(for: checks, version: "test")
        #expect(plain.contains("✓ [Done] Project access"))
        #expect(plain.contains("✗ [Incomplete] Local Network access"))
        #expect(plain.contains("1 step remains on the Mac"))
        #expect(!plain.contains("\u{1B}"))
        let colored = Doctor.text(for: checks, version: "test", color: true)
        #expect(colored.contains("\u{1B}[32m✓ [Done] Project access\u{1B}[0m"))
        #expect(colored.contains("\u{1B}[31m✗ [Incomplete] Local Network access\u{1B}[0m"))
        #expect(Doctor.text(for: [checks[0]], version: "test").contains("Mac checks passed"))
        #expect(!plain.contains("Check yourself"))
    }

    @Test func aMissingSelectedAgentDoesNotPassBecauseAnotherAgentIsInstalled() {
        let check = DoctorRuntime.destinationCheck(project: temporary.url, agent: "claude", available: [.codex])
        #expect(check.status == .needsYou)
        #expect(check.detail.contains("Install Claude Code"))
        let neither = DoctorRuntime.destinationCheck(project: temporary.url, agent: "auto", available: [])
        #expect(neither.status == .needsYou)
        #expect(neither.detail.contains("Install Codex or Claude Code"))
    }

    @Test func colorRespectsRedirectionAndTerminalPreferences() {
        #expect(Doctor.usesColor(isTerminal: true, environment: ["TERM": "xterm-256color"]))
        #expect(!Doctor.usesColor(isTerminal: false, environment: ["TERM": "xterm-256color"]))
        #expect(!Doctor.usesColor(isTerminal: true, environment: ["TERM": "dumb"]))
        #expect(!Doctor.usesColor(isTerminal: true, environment: ["NO_COLOR": "1"]))
        #expect(Doctor.usesColor(isTerminal: true, environment: ["NO_COLOR": ""]))
    }

    @Test func doctorRunsBeforeMigrationAndLeavesAgentSettingsUntouched() async throws {
        let home = temporary.url
        let old = home.appending(path: "Library/Application Support/Agentic Debugging/marker")
        try write("old data", to: old)
        let hooks = home.appending(path: ".codex/hooks.json")
        try write("{broken", to: hooks)
        let before = try Data(contentsOf: hooks)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = root.appending(path: ".build/debug/redline")
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
                timeout: 15,
                environment: fixtureEnvironment
            )
        }
        #expect(output?.contains("Redline doctor") == true)
        #expect(output?.contains("Doctor exit: 1") == true)
        #expect(output?.contains("\u{1B}") == false)
        #expect(output?.contains("Check yourself") == false)
        #expect(output?.contains("Developer Mode") == false)
        #expect(try String(contentsOf: old, encoding: .utf8) == "old data")
        #expect(try Data(contentsOf: hooks) == before)
        #expect(
            !FileManager.default.fileExists(atPath: home.appending(path: "Library/Application Support/Redline").path)
        )
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "Applications/Redline.app").path))
    }
}
#endif
