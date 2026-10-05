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
      redline setup | remove
          Adds to (or removes from) Codex's hook settings the hook that hands reports to a chat when
          nothing else can. Claude Code needs none. Other hooks stay as they are.
      redline hook <claude | codex> prompt
          Run by the agents' hooks, with the event's JSON on standard input.
      redline hub [--app <bundle ID> ...]
          Takes reports from phones and simulators for the open chats' apps and files them in the inbox.
          Chats start it when it isn't running.
      redline app [--app <bundle ID> ...]
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

// What the app and hub commands need is checked before the folder moves, which stops a hub of the
// earlier version that works, so it's never stopped for one that can't start.
let isHubCommand = ["app", "hub"].contains(arguments.first)
let hubDevicectl = isHubCommand ? Devicectl.locate() : nil
if isHubCommand, hubDevicectl == nil {
    let reason = "Couldn't find devicectl. Install Xcode and select it with xcode-select."
    if arguments.first == "app" { failToStart(reason) }
    printError(reason)
    exit(1)
}

// The folder an earlier version kept under the old name moves here before anything uses this one.
// A hub of that version stopped for the move is replaced at once, watching the apps it was given
// on the command line, so reports keep coming from them; the app and hub commands are that hub.
var movedApps: [String]?
switch HubPaths.moveFromOldName(to: paths) {
case .done:
    break
case .stoppedHub(let fixedApps):
    movedApps = fixedApps
case .blocked(let reason):
    switch arguments.first {
    case "app":
        failToStart(reason)
    case "hook":
        // The chat goes on as if no report were waiting for it.
        printError(reason)
        _ = FileHandle.standardInput.readDataToEndOfFile()
        guard arguments.count == 3, let event = HookEvent(rawValue: arguments[2]) else { exit(0) }
        exit(AgentHooks.answer(for: event, taken: nil))
    case "hub", "mcp", "check", "wait", "status":
        printError(reason)
        exit(1)
    default:
        // Setup, remove and the usage don't use the folder.
        break
    }
}
if let movedApps, !isHubCommand { HubProcess.startIfNeeded(paths, apps: movedApps) }

switch arguments.first {
case "app":
    // The menu bar app is the hub: one process. It watches the apps given with --app. A hub
    // already running steps aside, and the apps it was told to watch on the command line stay
    // watched. Launch Services may add arguments of its own, so ones it doesn't know are ignored.
    // What the app needs was checked first, so a hub that works is never stopped for one that can't
    // start.
    guard let devicectl = hubDevicectl else { exit(1) }
    let given = arguments.dropFirst()
    let givenApps = zip(given, given.dropFirst()).filter { $0.0 == "--app" }.map(\.1)
    var keptApps = givenApps + (movedApps ?? [])
    if let running = HubProcess.running(paths), running != getpid() {
        // A hub saves its status, with those apps, as it starts; give one starting now a moment.
        var status = savedStatus(paths)
        var tries = 0
        while status?.pid != running, HubProcess.running(paths) == running, tries < 50 {
            usleep(100_000)
            status = savedStatus(paths)
            tries += 1
        }
        if HubProcess.running(paths) == running {
            guard let status, status.pid == running else {
                failToStart(
                    "A hub is already running (pid \(running)) and didn't say which apps it watches, so it was left running."
                )
            }
            // A hub from before fixedApps was saved lists them only among all its apps. Such a
            // hub also lets go of the PID file at once when asked to stop, without waiting for
            // its hand-overs, so one handing a report over is left running: stopping it would
            // hand that report over twice.
            keptApps += status.fixedApps ?? status.apps
            if status.fixedApps == nil {
                let handingOver = Inbox.reportsHandedOver(by: running, paths: paths)
                guard handingOver == 0 else {
                    let reports =
                        handingOver == 1
                        ? "the report it's handing over reaches its chat"
                        : "the \(handingOver) reports it's handing over reach their chats"
                    failToStart(
                        "The hub that's running (pid \(running)) is from an older version. Open Redline again once \(reports)."
                    )
                }
            }
            // Asked to stop, the hub takes no more reports and starts no more hand-overs at once,
            // then lets the hand-overs under way reach their chats before it lets go of the PID file.
            // One that hasn't stopped in 30 seconds and isn't handing a report over is ended, which
            // frees the lock at once. One still handing a report over is never ended, or the report
            // would be handed over twice; a new chat can take minutes to look into a report, so
            // instead of waiting out of sight the app says why it can't start yet, and the hub stops
            // on its own once its reports are handed over.
            print("Waiting for the hub (pid \(running)) to stop")
            kill(running, SIGTERM)
            tries = 0
            var killedAt: Int?
            while HubProcess.running(paths) == running {
                if killedAt == nil, tries >= 300 {
                    let handingOver = Inbox.reportsHandedOver(by: running, paths: paths)
                    guard handingOver == 0 else {
                        let reports =
                            handingOver == 1
                            ? "the report it's handing over reaches its chat"
                            : "the \(handingOver) reports it's handing over reach their chats"
                        failToStart(
                            "The hub that was running (pid \(running)) stops once \(reports). Open Redline again then."
                        )
                    }
                    kill(running, SIGKILL)
                    killedAt = tries
                }
                if let killedAt, tries >= killedAt + 50 { break }
                usleep(100_000)
                tries += 1
            }
        }
    }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: unique(keptApps))
    // The listener can fail after the hub has started, such as when another process has the port;
    // the app then says so before it exits, rather than vanish.
    hub.whenListenerFails = { reason in
        Task { @MainActor in failToStart("\(reason). Phones and simulators can't send reports without it.") }
    }
    // Before the hub starts: once its status is written, the menu bar app opening next can ask
    // it to stop, and a hub without these handlers would be ended without letting go of its
    // hand-overs.
    stopOnSignals { hub.stop() }
    guard hub.start() else {
        failToStart("Another hub is running and didn't stop. Quit it, then open Redline again.")
    }
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
    guard let devicectl = hubDevicectl else { exit(1) }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: unique(options.apps + (movedApps ?? [])))
    // Before the hub starts, for the same reason as in the menu bar app.
    stopOnSignals { hub.stop() }
    guard hub.start() else {
        print("A hub is already running\(HubProcess.running(paths).map { " (pid \($0))" } ?? "").")
        exit(1)
    }
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
    var failed = false
    // New Claude Code chats need the claude command signed in. Without it, the other agents
    // still get their hooks, and setup reports the failure at the end.
    if adding, AgentSettings.isPresent(.claude) || AgentCommand.isClaudeAppInstalled() {
        if ClaudeCLI.prepare() {
            print("Claude Code: the claude command is signed in and ready to start new chats.")
        } else {
            failed = true
        }
    }
    for agent in Agent.allCases {
        guard AgentSettings.isPresent(agent) else {
            if adding { print("\(agent.name): not used on this Mac, skipped.") }
            continue
        }
        // An agent that needs no hooks only loses any an earlier version added; without those its
        // settings file isn't touched.
        let needsNoHooks = adding && AgentSettings.hooks(agent, executable: executable).isEmpty
        do {
            try AgentSettings.update(agent) {
                adding
                    ? AgentSettings.adding(agent, to: $0, executable: executable)
                    : AgentSettings.removing(agent, from: $0, executable: executable)
            }
            if needsNoHooks {
                print("\(agent.name): no hooks needed")
                continue
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
    if adding {
        print("Reports go to the chat picked on the phone, or else the chat in the worktree the app was built from.")
    }
    exit(failed ? 1 : 0)

case "status":
    printStatus(paths)

default:
    print(usage, terminator: "")
}

/// The running hub's saved status, nil until it has saved one.
///
/// A status that can't be read counts as not saved yet: a hub writes it whole as it starts.
@MainActor
func savedStatus(_ paths: HubPaths) -> HubStatus? {
    do {
        return try HubPaths.decoder.decode(HubStatus.self, from: Data(contentsOf: paths.status))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    } catch {
        printError("Couldn't read the running hub's status: \(error.localizedDescription)")
        return nil
    }
}

/// Says why the menu bar app can't start, then exits.
///
/// Opened from Finder or by a chat, the app has no terminal to print to, so it shows the reason in
/// an alert too.
@MainActor
func failToStart(_ reason: String) -> Never {
    printError(reason)
    if Bundle.main.bundleURL.pathExtension == "app" {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = "Redline couldn't start"
        alert.informativeText = reason
        alert.runModal()
    }
    exit(1)
}

/// `apps` without repeats, in their order.
func unique(_ apps: [String]) -> [String] {
    var seen = Set<String>()
    return apps.filter { seen.insert($0).inserted }
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
    guard !taken.reports.isEmpty else {
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
    // The reports are the chat's once they're written out.
    ChatSession.settle(taken.reports, isDelivered: fflush(stdout) == 0 && ferror(stdout) == 0)
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
            print(
                status.hosts.isEmpty
                    ? "  Not on a network, so apps can't reach it"
                    : "  Apps reach it at \(status.hosts.joined(separator: ", ")), port \(status.port)"
            )
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
