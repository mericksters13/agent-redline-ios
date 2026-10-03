#if os(macOS)
import Foundation

/// `agentic-debugging`: the Mac side of iOSAgenticDebuggingKit. It takes reports off paired
/// phones and simulators and keeps them in an inbox on the Mac for agent chats.
let usage = """
Usage:
  agentic-debugging hub --app <bundle ID> [--app <bundle ID> ...]
      Takes reports from these apps on paired phones and simulators and files them in the inbox.
  agentic-debugging status
      Shows what the hub is watching and what's in the inbox.

"""

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = HubPaths.standard

switch arguments.first {
case "hub":
    var apps: [String] = []
    var rest = arguments.dropFirst()
    while let flag = rest.popFirst() {
        guard flag == "--app", let bundleID = rest.popFirst() else {
            FileHandle.standardError.write(Data(usage.utf8))
            exit(64)
        }
        apps.append(bundleID)
    }
    guard !apps.isEmpty else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(64)
    }
    if let running = runningHub(paths) {
        print("A hub is already running (pid \(running)).")
        exit(1)
    }
    guard let devicectl = Devicectl.locate() else {
        print("Couldn't find devicectl. Install Xcode and select it with xcode-select.")
        exit(1)
    }
    let hub = Hub(paths: paths, devicectl: devicectl, apps: apps)
    hub.start()
    var signals: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            hub.stop()
            exit(0)
        }
        source.resume()
        signals.append(source)
    }
    dispatchMain()

case "status":
    printStatus(paths)

default:
    print(usage, terminator: "")
}

/// The pid of a hub that's running, if any.
func runningHub(_ paths: HubPaths) -> Int32? {
    guard let text = try? String(contentsOf: paths.pid, encoding: .utf8), let pid = Int32(text), kill(pid, 0) == 0 else { return nil }
    return pid
}

func printStatus(_ paths: HubPaths) {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let pid = runningHub(paths), let data = try? Data(contentsOf: paths.status), let status = try? decoder.decode(HubStatus.self, from: data) {
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
