#if os(macOS)
import AppKit
import Foundation
import UserNotifications

/// `redline`: the Mac side of Agent Redline. It takes reports off paired
/// phones and simulators and keeps them in an inbox on the Mac for agent chats.
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
      Adds to (or removes from) Codex's and Cursor's hook settings the hooks that hand reports to
      a chat when nothing else can. Claude Code needs none. Other hooks stay as they are.
  redline hook <claude | codex | cursor> <start | prompt | stop | end>
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
    var project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var apps: [String] = []
    var timeout: TimeInterval?
    var session: String?
    var agent = "command line"

    init(_ arguments: ArraySlice<String>) {
        var rest = arguments
        while let flag = rest.popFirst() {
            switch (flag, rest.popFirst()) {
            case ("--project", let value?): project = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case ("--app", let value?): apps.append(value)
            case ("--timeout", let value?): timeout = TimeInterval(value)
            case ("--session", let value?): session = value
            case ("--agent", let value?): agent = value
            default:
                FileHandle.standardError.write(Data(usage.utf8))
                exit(64)
            }
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
let paths = HubPaths.standard
HubPaths.moveFromOldName(to: paths)
// Opened as an app bundle, it's the menu bar app.
if arguments.isEmpty, Bundle.main.bundleURL.pathExtension == "app" { arguments = ["app"] }

switch arguments.first {
case "app":
    // The menu bar app is the hub: one process. A hub already running steps aside.
    if let running = HubProcess.running(paths), running != getpid() {
        kill(running, SIGTERM)
        for _ in 0..<20 where HubProcess.running(paths) != nil { usleep(100_000) }
    }
    guard let devicectl = Devicectl.locate() else {
        print("Couldn't find devicectl. Install Xcode and select it with xcode-select.")
        exit(1)
    }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: [])
    hub.start()
    stopOnSignals { hub.stop() }
    HubAppContext.hub = hub
    // Report notifications come from Redline; macOS asks the user once.
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    NSApplication.shared.setActivationPolicy(.accessory)
    HubMenuBarApp.main()

case "hub":
    let options = ChatOptions(arguments.dropFirst())
    if let running = HubProcess.running(paths) {
        print("A hub is already running (pid \(running)).")
        exit(1)
    }
    guard let devicectl = Devicectl.locate() else {
        print("Couldn't find devicectl. Install Xcode and select it with xcode-select.")
        exit(1)
    }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: options.apps)
    hub.start()
    stopOnSignals { hub.stop() }
    dispatchMain()

case "mcp":
    let options = ChatOptions(arguments.dropFirst())
    let session = ChatSession(paths: paths, folder: options.project, extraApps: options.apps, agent: "unknown")
    stopOnSignals { session.unregister() }
    MCPServer(session: session).run()

case "check":
    let options = ChatOptions(arguments.dropFirst())
    let session = ChatSession(paths: paths, folder: options.project, extraApps: options.apps, agent: "command line")
    printReports(session)

case "wait":
    let options = ChatOptions(arguments.dropFirst())
    let session = ChatSession(paths: paths, folder: options.project, extraApps: options.apps, agent: options.agent, id: options.session)
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
    let deadline = options.timeout.map { Date().addingTimeInterval($0) }
    while true {
        let left = deadline.map { $0.timeIntervalSinceNow }
        guard session.waitForRoutedReport(timeout: left, waiter: waiter) else {
            session.unregister()
            print("No report arrived.")
            break
        }
        // Another chat may have taken it in the meantime; then keep waiting.
        if printReports(session, quietWhenNone: true) {
            session.unregister()
            break
        }
    }

case "hook":
    guard arguments.count == 3, let agent = Agent(rawValue: arguments[1]), let event = HookEvent(rawValue: arguments[2]) else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }
    exit(AgentHooks.run(agent, event, paths: paths))

case "setup", "remove":
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let adding = arguments.first == "setup"
    // Before anything else: new Claude Code chats need the claude command signed in.
    if adding, AgentSettings.isPresent(.claude) || AgentCommand.hasClaudeApp {
        guard ClaudeCLI.prepare() else { exit(1) }
        print("Claude Code: the claude command is signed in and ready to start new chats.")
    }
    var failed = false
    for agent in Agent.allCases {
        guard AgentSettings.isPresent(agent) else {
            if adding { print("\(agent.name): not used on this Mac, skipped.") }
            continue
        }
        do {
            try AgentSettings.update(agent) {
                adding ? AgentSettings.adding(agent, to: $0, executable: executable) : AgentSettings.removing(agent, from: $0)
            }
            if adding, AgentSettings.hooks(agent, executable: executable).isEmpty {
                print("\(agent.name): no hooks needed")
            } else {
                print("\(agent.name): \(adding ? "hooks added to" : "hooks removed from") \(AgentSettings.file(agent).path)")
            }
            if adding, agent == .codex { print("  Codex runs a new hook only once you trust it: open /hooks in Codex and trust \"Report delivery\".") }
        } catch {
            print("\(agent.name): couldn't update \(AgentSettings.file(agent).path): \(error.localizedDescription)")
            failed = true
        }
    }
    if adding { print("Reports go to the chat picked on the phone, or else the chat in the worktree the app was built from.") }
    exit(failed ? 1 : 0)

case "status":
    printStatus(paths)

default:
    print(usage, terminator: "")
}

/// Runs `cleanup` and exits on Control-C or a termination request.
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

/// Kept alive for as long as the process runs. A static, not a top-level variable: those
/// start existing only when execution reaches their line, after the commands above use this.
enum SignalSources {
    nonisolated(unsafe) static var all: [DispatchSourceSignal] = []
}

/// Prints the reports waiting for the session's apps and takes them. Pictures are named by
/// path; an agent opens them with its own tools. True when it printed any.
@discardableResult
func printReports(_ session: ChatSession, quietWhenNone: Bool = false) -> Bool {
    let taken = session.take(budget: Int.max)
    guard taken.taken > 0 else {
        if !quietWhenNone {
            print(session.chat.bundleIDs.isEmpty ? "No app found for \(session.chat.folder). Pass --app <bundle ID>." : "No reports waiting for \(session.chat.bundleIDs.joined(separator: ", ")).")
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

func printStatus(_ paths: HubPaths) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let pid = HubProcess.running(paths), let data = try? Data(contentsOf: paths.status), let status = try? decoder.decode(HubStatus.self, from: data) {
        print("Hub running (pid \(pid)) since \(status.startedAt.formatted(date: .omitted, time: .shortened)), for \(status.apps.joined(separator: ", "))")
        print("  Apps reach it at \(status.hosts.joined(separator: ", ")), port \(status.port)")
        for phone in status.phones { print("  \(phone.name) (\(phone.udid)): \(phone.state)") }
        print("  Simulators: \(status.simulatorContainers) app \(status.simulatorContainers == 1 ? "container" : "containers") watched")
    } else {
        print("Hub not running")
    }
    let files = FileManager.default
    let apps = ((try? files.contentsOfDirectory(atPath: paths.inbox.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    guard !apps.isEmpty else {
        print("Inbox empty")
        return
    }
    print("Inbox (\(paths.inbox.path)):")
    for app in apps {
        let reports = ((try? files.contentsOfDirectory(atPath: paths.inbox.appending(path: app).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let newest = reports.last.flatMap { name -> String? in
            guard let data = try? Data(contentsOf: paths.inbox.appending(path: "\(app)/\(name)/source.json")),
                  let source = try? decoder.decode(ReportSource.self, from: data) else { return name }
            return "\(name), from \(source.deviceName), received \(source.receivedAt.formatted(.relative(presentation: .named)))"
        }
        print("  \(app): \(reports.count) \(reports.count == 1 ? "report" : "reports")" + (newest.map { "; newest \($0)" } ?? ""))
    }
}
#else
print("redline runs on the Mac.")
#endif
