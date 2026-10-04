#if os(macOS)
import AppKit
import Foundation
import UserNotifications

// `redline`: the Mac side of Redline. It takes reports off paired phones and simulators and
// keeps them in an inbox on the Mac for agent chats.

/// The tool's version, which the MCP server reports. scripts/build-hub-app.sh writes the same
/// into the app bundle.
let version = "0.1.0"

/// The help text printed for `redline` with no or unknown arguments.
let usage = """
    Usage:
      redline mcp [--project <folder>] [--app <bundle ID> ...]
          The MCP server for one agent chat. Registers the chat for the apps its project builds,
          starts the hub if needed, and offers check_messages and wait_for_message.
      redline check [--project <folder>] [--app <bundle ID> ...]
          Prints the reports waiting for the project's apps and takes them, for agents without MCP.
      redline wait [--project <folder>] [--app <bundle ID> ...] [--timeout <seconds>]
                   [--session <chat ID>] [--agent <name>]
          Waits for the next report for the project's apps, then prints it and takes it. Run in an
          agent's background, it wakes the chat when a report arrives. With several chats waiting,
          the one used most recently gets the report.
      redline setup [--no-input]
          Checks that the claude command is installed, new enough and signed in, running claude
          update and claude auth login in this terminal when needed, and adds the Codex hook that
          hands reports to a chat when nothing else can. Claude Code needs no hooks, and Cursor's
          from an earlier setup are removed. Other hooks stay as they are. With --no-input, or with
          no terminal, it only prints what you need to run.
      redline remove
          Removes Redline's hooks from Codex and Claude Code settings, and Cursor's from an earlier
          setup. Other hooks stay.
      redline hook <claude | codex> prompt
          Run by the agents' hooks, with the event's JSON on standard input.
      redline hub [--app <bundle ID> ...]
          Takes reports from phones and simulators for the open chats' apps and files them in the inbox.
          Chats start it when it isn't running.
      redline app
          The hub as a menu bar app, showing the active devices and the reports sent. Opening the
          app bundle does the same.
      redline status
          Shows what the hub is doing and what's in the inbox.

    """

/// The options the chat commands share.
struct ChatOptions {
    var project = URL(filePath: FileManager.default.currentDirectoryPath)
    var apps: [String] = []
    var timeout: TimeInterval?
    var session: String?
    var agent = "command line"

    /// The options in `arguments`; nil for a flag it doesn't know or one without its value.
    static func parse(_ arguments: ArraySlice<String>) -> ChatOptions? {
        var options = ChatOptions()
        var rest = arguments
        while let flag = rest.popFirst() {
            switch (flag, rest.popFirst()) {
            case ("--project", let value?): options.project = URL(filePath: (value as NSString).expandingTildeInPath)
            case ("--app", let value?): options.apps.append(value)
            case ("--timeout", let value?): options.timeout = TimeInterval(value)
            case ("--session", let value?): options.session = value
            case ("--agent", let value?): options.agent = value
            default: return nil
            }
        }
        return options
    }

    /// The options in `arguments`, or the usage printed and an exit with code 64.
    static func parseOrExit(_ arguments: ArraySlice<String>) -> ChatOptions {
        guard let options = parse(arguments) else {
            printError(usage)
            exit(64)
        }
        return options
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let paths = HubPaths.standard
// Opened as an app bundle, it's the menu bar app.
if arguments.isEmpty, Bundle.main.bundleURL.pathExtension == "app" { arguments = ["app"] }

switch arguments.first {
case "app":
    // The menu bar app is the hub: one process. A hub already running steps aside, and the apps
    // it was told to watch on the command line stay watched.
    var keptApps: [String] = []
    if let running = HubProcess.running(paths), running != getpid() {
        do {
            let status = try HubPaths.decoder.decode(HubStatus.self, from: Data(contentsOf: paths.status))
            if status.pid == running { keptApps = status.fixedApps ?? [] }
        } catch {
            printError(
                "Couldn't read the running hub's status; its command-line apps aren't kept: \(error.localizedDescription)"
            )
        }
        kill(running, SIGTERM)
        for _ in 0..<20 where HubProcess.running(paths) != nil { usleep(100_000) }
    }
    guard let devicectl = Devicectl.locate() else {
        print("Couldn't find devicectl. Install Xcode and select it with xcode-select.")
        exit(1)
    }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: keptApps)
    guard hub.start() else {
        print("Another hub is running and didn't stop. Quit it, then open Redline again.")
        exit(1)
    }
    stopOnSignals { hub.stop() }
    HubAppContext.hub = hub
    // Report notifications come from Redline; macOS asks the user once.
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    NSApplication.shared.setActivationPolicy(.accessory)
    HubMenuBarApp.main()

case "hub":
    let options = ChatOptions.parseOrExit(arguments.dropFirst())
    if let running = HubProcess.running(paths) {
        print("A hub is already running (pid \(running)).")
        exit(1)
    }
    guard let devicectl = Devicectl.locate() else {
        print("Couldn't find devicectl. Install Xcode and select it with xcode-select.")
        exit(1)
    }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: options.apps)
    guard hub.start() else {
        print("A hub is already running\(HubProcess.running(paths).map { " (pid \($0))" } ?? "").")
        exit(1)
    }
    stopOnSignals { hub.stop() }
    dispatchMain()

case "mcp":
    let options = ChatOptions.parseOrExit(arguments.dropFirst())
    let session = ChatSession(paths: paths, folder: options.project, extraApps: options.apps, agent: "unknown")
    stopOnSignals { session.unregister() }
    MCPServer(session: session).run()

case "check":
    let options = ChatOptions.parseOrExit(arguments.dropFirst())
    let session = ChatSession(paths: paths, folder: options.project, extraApps: options.apps, agent: "command line")
    printReports(session)

case "wait":
    let options = ChatOptions.parseOrExit(arguments.dropFirst())
    let session = ChatSession(
        paths: paths,
        folder: options.project,
        extraApps: options.apps,
        agent: options.agent,
        id: options.session
    )
    guard !session.chat.bundleIDs.isEmpty else {
        print("No app found for \(options.project.path). Pass --app <bundle ID>.")
        exit(1)
    }
    // Registered while waiting, so the hub takes this project's reports and they come here.
    session.registerWaiting()
    stopOnSignals { session.unregister() }
    // The chat that started the wait closed: stop waiting, so no report goes to a closed chat.
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .global())
    parent.setEventHandler {
        session.unregister()
        exit(0)
    }
    parent.resume()
    let waiter = ChatSession.Waiter()
    let deadline = options.timeout.map { Date.now.addingTimeInterval($0) }
    while true {
        let left = deadline.map { $0.timeIntervalSinceNow }
        guard session.waitForRoutedReport(timeout: left, waiter: waiter) else {
            session.unregister()
            print("No report arrived.")
            break
        }
        // Another chat may have taken it in the meantime; then keep waiting.
        if printReports(session, isQuietWhenNone: true) {
            session.unregister()
            break
        }
    }

case "hook":
    guard arguments.count == 3, let agent = Agent(rawValue: arguments[1]), let event = HookEvent(rawValue: arguments[2])
    else {
        printError(usage)
        exit(64)
    }
    exit(AgentHooks.run(for: agent, event: event, paths: paths))

case "setup", "remove":
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let adding = arguments.first == "setup"
    let options = arguments.dropFirst()
    guard options.isEmpty || (adding && options == ["--no-input"]) else {
        printError(usage)
        exit(64)
    }
    // First: new Claude Code chats need the claude command signed in. What's still missing is
    // printed for the user, and setup goes on.
    if adding, AgentSettings.isPresent(.claude) || AgentCommand.isClaudeAppInstalled(),
        ClaudeCLI.prepare(isAsking: options.isEmpty && isatty(STDIN_FILENO) != 0)
    {
        print("Claude Code: the claude command is signed in and ready to start new chats.")
    }
    var failed = false
    for agent in Agent.allCases {
        guard AgentSettings.isPresent(agent) else {
            if adding { print("\(agent.name): not used on this Mac, skipped.") }
            continue
        }
        // An agent that needs no hooks is left alone: its settings file isn't touched.
        if adding, AgentSettings.hooks(agent, executable: executable).isEmpty {
            print("\(agent.name): no hooks needed")
            continue
        }
        do {
            try AgentSettings.update(agent) {
                adding
                    ? AgentSettings.adding(agent, to: $0, executable: executable)
                    : AgentSettings.removing(from: $0, executable: executable)
            }
            print(
                "\(agent.name): \(adding ? "hooks added to" : "hooks removed from") \(AgentSettings.fileURL(for: agent).path)"
            )
            if adding, agent == .codex {
                print(
                    "  Codex runs a new hook only once you trust it: open /hooks in Codex and trust \"Report delivery\"."
                )
            }
        } catch {
            print(
                "\(agent.name): couldn't update \(AgentSettings.fileURL(for: agent).path): \(error.localizedDescription)"
            )
            failed = true
        }
    }
    // Cursor isn't supported. Setup and remove both take out the hooks an earlier setup added
    // for it, so none is left running a command that is later removed.
    let cursorFile = AgentSettings.cursorFileURL()
    do {
        if try AgentSettings.containsHooks(inFile: cursorFile, executable: executable) {
            try AgentSettings.update(cursorFile) { AgentSettings.removing(from: $0, executable: executable) }
            print("Cursor: hooks from an earlier setup removed from \(cursorFile.path)")
        }
    } catch {
        print("Cursor: couldn't update \(cursorFile.path): \(error.localizedDescription)")
        failed = true
    }
    if adding {
        print("Reports go to the chat picked on the phone, or else the chat in the worktree the app was built from.")
    }
    exit(failed ? 1 : 0)

case "status":
    printStatus(paths)

default:
    print(usage, terminator: "")
}

/// Writes a line to standard error.
func printError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
}

/// Runs `cleanup` and exits on Control-C or a termination request.
///
/// Called from the top-level code above, on the main actor.
@MainActor
func stopOnSignals(_ cleanup: @escaping @Sendable () -> Void) {
    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            cleanup()
            exit(0)
        }
        source.resume()
        SignalSources.all.append(source)
    }
}

/// Kept alive for as long as the process runs.
///
/// A static, not a top-level variable: those start existing only when execution reaches their line,
/// after the commands above use this.
@MainActor
enum SignalSources {
    static var all: [DispatchSourceSignal] = []
}

/// Prints the reports waiting for the session's apps and takes them.
///
/// Pictures are named by path; an agent opens them with its own tools. True when it printed any.
@discardableResult
func printReports(_ session: ChatSession, isQuietWhenNone: Bool = false) -> Bool {
    let taken = session.take(budget: Int.max)
    guard taken.taken > 0 else {
        if !isQuietWhenNone {
            print(
                session.chat.bundleIDs.isEmpty
                    ? "No app found for \(session.chat.folder). Pass --app <bundle ID>."
                    : "No reports waiting for \(session.chat.bundleIDs.joined(separator: ", "))."
            )
        }
        return false
    }
    for item in taken.items {
        switch item {
        case .text(let text): print(text)
        case .image(let file, _): print("Picture: \(file.path)")
        }
    }
    return true
}

/// Prints what the hub is doing and what's in the inbox, for `redline status`.
func printStatus(_ paths: HubPaths) {
    let decoder = HubPaths.decoder
    if let pid = HubProcess.running(paths) {
        do {
            let status = try decoder.decode(HubStatus.self, from: Data(contentsOf: paths.status))
            print(
                "Hub running (pid \(pid)) since \(status.startedAt.formatted(date: .omitted, time: .shortened)), for \(status.apps.joined(separator: ", "))"
            )
            print("  Apps reach it at \(status.hosts.joined(separator: ", ")), port \(status.port)")
            for phone in status.phones {
                print(
                    "  \(phone.name) (\([phone.model, phone.udid].compactMap { $0 }.joined(separator: ", "))): \(phone.state)"
                )
            }
            print(
                "  Simulators: \(status.simulatorContainers) app \(status.simulatorContainers == 1 ? "container" : "containers") watched"
            )
        } catch {
            print("Hub running (pid \(pid)), but its status couldn't be read: \(error.localizedDescription)")
        }
    } else {
        print("Hub not running")
    }
    let reports = Dictionary(grouping: Inbox.reports(for: nil, paths: paths), by: \.source.bundleID)
    guard !reports.isEmpty else {
        print("Inbox empty")
        return
    }
    print("Inbox (\(paths.inbox.path)):")
    for (app, reports) in reports.sorted(by: { $0.key < $1.key }) {
        let newest = reports.last.map { report in
            "\(report.folder.lastPathComponent), from \(report.source.deviceName), received \(report.source.receivedAt.formatted(.relative(presentation: .named)))"
        }
        print(
            "  \(app): \(reports.count) \(reports.count == 1 ? "report" : "reports")"
                + (newest.map { "; newest \($0)" } ?? "")
        )
    }
}
#else
print("redline runs on the Mac.")
#endif
