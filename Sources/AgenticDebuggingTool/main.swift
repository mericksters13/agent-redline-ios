#if os(macOS)
import Foundation

/// `agentic-debugging`: the Mac side of iOSAgenticDebuggingKit. It takes reports off paired
/// phones and simulators and keeps them in an inbox on the Mac for agent chats.
let usage = """
Usage:
  agentic-debugging mcp [--project <folder>] [--app <bundle ID> ...]
      The MCP server for one agent chat. Registers the chat for the apps its project builds,
      starts the hub if needed, and offers check_messages and wait_for_message.
  agentic-debugging check [--project <folder>] [--app <bundle ID> ...]
      Prints the reports waiting for the project's apps and takes them, for agents without MCP.
  agentic-debugging wait [--project <folder>] [--app <bundle ID> ...] [--timeout <seconds>]
      Waits for the next report for the project's apps, then prints it and takes it.
  agentic-debugging hub [--app <bundle ID> ...]
      Takes reports from phones and simulators for the open chats' apps and files them in the inbox.
      Chats start it when it isn't running.
  agentic-debugging status
      Shows what the hub is doing and what's in the inbox.

"""

/// The options the chat commands share.
struct ChatOptions {
    var project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var apps: [String] = []
    var timeout: TimeInterval?

    init(_ arguments: ArraySlice<String>) {
        var rest = arguments
        while let flag = rest.popFirst() {
            switch (flag, rest.popFirst()) {
            case ("--project", let value?): project = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            case ("--app", let value?): apps.append(value)
            case ("--timeout", let value?): timeout = TimeInterval(value)
            default:
                FileHandle.standardError.write(Data(usage.utf8))
                exit(64)
            }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = HubPaths.standard

switch arguments.first {
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
    let session = ChatSession(paths: paths, folder: options.project, extraApps: options.apps, agent: "command line")
    guard !session.chat.bundleIDs.isEmpty else {
        print("No app found for \(options.project.path). Pass --app <bundle ID>.")
        exit(1)
    }
    // Registered while waiting, so the hub takes this project's reports.
    session.register()
    stopOnSignals { session.unregister() }
    let arrived = session.waitForReport(timeout: options.timeout, waiter: ChatSession.Waiter())
    session.unregister()
    if arrived {
        printReports(session)
    } else {
        print("No report arrived.")
    }

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
/// path; an agent opens them with its own tools.
func printReports(_ session: ChatSession) {
    let taken = session.take(budget: Int.max)
    guard taken.taken > 0 else {
        print(session.chat.bundleIDs.isEmpty ? "No app found for \(session.chat.folder). Pass --app <bundle ID>." : "No reports waiting for \(session.chat.bundleIDs.joined(separator: ", ")).")
        return
    }
    for item in taken.items {
        switch item {
        case .text(let text): print(text)
        case .image(let file, _): print("Picture: \(file.path)")
        }
    }
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
print("agentic-debugging runs on the Mac.")
#endif
