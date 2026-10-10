#if os(macOS)
import Foundation

/// What remains before the first report, checked in the processes that use the access.
enum Doctor {
    enum Status: String, Codable, Sendable {
        case done = "Done"
        case needsYou = "Incomplete"
    }

    struct Check: Codable, Sendable {
        var status: Status
        var name: String
        var detail: String
    }

    static func options(_ arguments: ArraySlice<String>) -> (project: URL, agent: String)? {
        var project = URL(filePath: FileManager.default.currentDirectoryPath)
        var agent = "auto"
        var rest = arguments
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst(), !value.isEmpty else { return nil }
            switch flag {
            case "--project": project = URL(filePath: (value as NSString).expandingTildeInPath)
            case "--agent":
                guard Agent(rawValue: value) != nil else { return nil }
                agent = value
            default: return nil
            }
        }
        return (project.standardizedFileURL, agent)
    }

    static func checks(
        project: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        agent: String = "auto",
        home: URL = AgentSettings.homeDirectory(),
        app: URL? = HubProcess.installedApp()
    ) -> [Check] {
        let paths = HubPaths(root: home.appending(path: "Library/Application Support/Redline"))
        var checks = installationChecks(home: home, app: app)
        guard checks.allSatisfy({ $0.status == .done }) else { return checks }
        let request = DoctorConnection.Request(project: project.path, agent: agent)
        guard let reply = DoctorConnection.query(request, paths: paths),
            reply.id == request.id, reply.pid == HubProcess.running(paths),
            reply.isMacApp == false || !reply.checks.isEmpty
        else {
            checks.append(
                Check(
                    status: .needsYou,
                    name: "Mac access checks",
                    detail:
                        "Update the Redline Mac app and reopen it, then rerun doctor. The running copy did not answer this check."
                )
            )
            return checks
        }
        guard reply.isMacApp else {
            checks.append(
                Check(
                    status: .needsYou,
                    name: "Redline Mac app",
                    detail:
                        "The hub is running outside the Redline Mac app. Open the installed Redline app and rerun doctor so its Mac permissions can be checked."
                )
            )
            return checks
        }
        checks += reply.checks
        return checks
    }

    /// Starting the hub is an action; observing its lock and status does not start it.
    static func installationChecks(home: URL, app: URL?) -> [Check] {
        let paths = HubPaths(root: home.appending(path: "Library/Application Support/Redline"))
        guard let pid = HubProcess.running(paths) else {
            return [
                Check(
                    status: .needsYou,
                    name: "Redline hub",
                    detail: app == nil
                        ? "Install the Redline Mac helper: npx agent-redline-ios. Then open Redline and rerun doctor."
                        : "Open Redline: open -b com.agentredline.hub. Then rerun doctor."
                )
            ]
        }
        let status = (try? Data(contentsOf: paths.status)).flatMap {
            try? HubPaths.decoder.decode(HubStatus.self, from: $0)
        }
        return [
            Check(
                status: status?.pid == pid ? .done : .needsYou,
                name: "Redline hub",
                detail: status?.pid == pid
                    ? "Running."
                    : "The hub is starting or its saved status is stale. Wait a moment and rerun doctor; if it persists, reopen Redline."
            )
        ]
    }

    static func exitCode(for checks: [Check]) -> Int32 {
        checks.contains { $0.status == .needsYou } ? 1 : 0
    }

    static func usesColor(isTerminal: Bool, environment: [String: String]) -> Bool {
        isTerminal && environment["TERM"] != "dumb" && environment["NO_COLOR"]?.isEmpty != false
    }

    static func text(for checks: [Check], version: String, color: Bool = false) -> String {
        let lines = checks.map { check in
            let passed = check.status == .done
            let heading = "\(passed ? "✓" : "✗") [\(check.status.rawValue)] \(check.name)"
            let styled = color ? "\u{1B}[\(passed ? 32 : 31)m\(heading)\u{1B}[0m" : heading
            return "\(styled)\n  \(check.detail.replacing("\n", with: "\n  "))"
        }.joined(separator: "\n\n")
        let missing = checks.filter { $0.status == .needsYou }.count
        let summary =
            missing == 0 && !checks.isEmpty
            ? "Mac checks passed. In your Debug app, tap Redline, add a note, choose this project's chat and Send."
            : "\(missing) \(missing == 1 ? "step remains" : "steps remain") on the Mac. Complete the actions above and rerun doctor."
        return "Redline doctor \(version)\nMac setup for your first report\n\n\(lines)\n\n\(summary)"
    }
}
#endif
