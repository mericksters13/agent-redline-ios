#if os(macOS)
import Foundation

/// Xcode's command-line tool for paired devices. Every call starts a short-lived process and
/// reads its JSON result; a failure means the phone can't be reached right now.
struct Devicectl: Sendable {
    let executable: URL

    /// Finds `devicectl` through `xcrun` once.
    static func locate() -> Devicectl? {
        guard let output = run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["--find", "devicectl"]).output,
              let path = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return Devicectl(executable: URL(fileURLWithPath: path))
    }

    struct Phone: Equatable, Sendable {
        var udid: String
        var name: String
        var model: String
    }

    /// The iPhones and iPads paired with this Mac, reachable or not.
    func pairedPhones() -> [Phone]? {
        struct Response: Decodable {
            struct Result: Decodable { var devices: [Device] }
            struct Device: Decodable {
                struct Hardware: Decodable { var udid: String?; var platform: String?; var reality: String?; var marketingName: String? }
                struct Properties: Decodable { var name: String? }
                struct Connection: Decodable { var pairingState: String? }
                var hardwareProperties: Hardware?
                var deviceProperties: Properties?
                var connectionProperties: Connection?
            }
            var result: Result
        }
        guard let response: Response = json(["list", "devices"]) else { return nil }
        return response.result.devices.compactMap { device in
            guard let hardware = device.hardwareProperties, hardware.platform == "iOS", hardware.reality == "physical",
                  device.connectionProperties?.pairingState == "paired", let udid = hardware.udid
            else { return nil }
            return Phone(udid: udid, name: device.deviceProperties?.name ?? udid, model: hardware.marketingName ?? "")
        }
    }

    /// Whether an app is installed on the phone; nil when the phone can't be reached.
    func isInstalled(_ bundleID: String, on udid: String) -> Bool? {
        struct Response: Decodable {
            struct Result: Decodable { var apps: [App] }
            struct App: Decodable { var bundleIdentifier: String? }
            var result: Result
        }
        let response: Response? = json(["device", "info", "apps", "--device", udid, "--bundle-id", bundleID])
        return response.map { $0.result.apps.contains { $0.bundleIdentifier == bundleID } }
    }

    /// The app's finished reports on the phone; nil when they can't be listed, because the
    /// phone can't be reached or the app hasn't sent a report yet.
    func finishedReports(of bundleID: String, on udid: String) -> [FinishedReport]? {
        struct Response: Decodable {
            struct Result: Decodable { var files: [File] }
            struct File: Decodable {
                struct Metadata: Decodable { var lastModDate: String? }
                var relativePath: String
                var metadata: Metadata?
            }
            var result: Result
        }
        guard let response: Response = json([
            "device", "info", "files", "--device", udid, "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID, "--subdirectory", ReportFolder.path,
        ]) else { return nil }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ReportFolder.finished(in: response.result.files.map { file in
            (file.relativePath, file.metadata?.lastModDate.flatMap { dates.date(from: $0) })
        })
    }

    /// Copies one report folder off the phone into `destination`, which must not exist yet.
    func copyReport(_ id: String, of bundleID: String, on udid: String, to destination: URL) -> Bool {
        let result = Self.run(executable, [
            "device", "copy", "from", "--device", udid, "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID, "--source", "\(ReportFolder.path)/\(id)", "--destination", destination.path, "--quiet",
        ])
        return result.status == 0 && FileManager.default.fileExists(atPath: destination.appending(path: "report.json").path)
    }

    /// Writes a small file into an app's data container on the phone, creating its folders.
    func write(_ data: Data, to path: String, of bundleID: String, on udid: String) -> Bool {
        let file = FileManager.default.temporaryDirectory.appending(path: "agentic-debugging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? data.write(to: file)) != nil else { return false }
        return Self.run(executable, [
            "device", "copy", "to", "--device", udid, "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID, "--source", file.path, "--destination", path, "--quiet",
        ]).status == 0
    }

    private func json<T: Decodable>(_ arguments: [String]) -> T? {
        let file = FileManager.default.temporaryDirectory.appending(path: "agentic-debugging-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = Self.run(executable, arguments + ["--json-output", file.path, "--quiet"])
        guard result.status == 0, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: Data?) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, nil)
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
#endif
