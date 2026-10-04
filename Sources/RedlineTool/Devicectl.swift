#if os(macOS)
import Foundation

/// Xcode's command-line tool for paired devices. Every call starts a short-lived process and
/// reads its JSON result.
struct Devicectl: Sendable {
    let executable: URL

    /// Finds `devicectl` through `xcrun` once.
    static func locate() -> Devicectl? {
        guard let result = try? run(URL(filePath: "/usr/bin/xcrun"), arguments: ["--find", "devicectl"]), result.status == 0,
              let path = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return Devicectl(executable: URL(filePath: path))
    }

    struct Phone: Equatable, Sendable {
        var udid: String
        var name: String
        var model: String
    }

    /// The iPhones and iPads paired with this Mac, reachable or not. Throws when devicectl fails
    /// or prints something this tool can't read.
    func pairedPhones() throws -> [Phone] {
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
        let response: Response = try runJSON(["list", "devices"])
        return response.result.devices.compactMap { device in
            guard let hardware = device.hardwareProperties, hardware.platform == "iOS", hardware.reality == "physical",
                  device.connectionProperties?.pairingState == "paired", let udid = hardware.udid
            else { return nil }
            return Phone(udid: udid, name: device.deviceProperties?.name ?? udid, model: hardware.marketingName ?? "")
        }
    }

    /// Whether an app is on a phone, as far as devicectl can tell.
    enum Installation: Equatable {
        case installed
        case notInstalled
        /// The phone can't be reached right now, or devicectl's answer couldn't be read.
        case unreachable
    }

    func installation(of bundleID: String, on udid: String) -> Installation {
        struct Response: Decodable {
            struct Result: Decodable { var apps: [App] }
            struct App: Decodable { var bundleIdentifier: String? }
            var result: Result
        }
        guard let response: Response = try? runJSON(["device", "info", "apps", "--device", udid, "--bundle-id", bundleID]) else { return .unreachable }
        return response.result.apps.contains { $0.bundleIdentifier == bundleID } ? .installed : .notInstalled
    }

    /// Writes a small file into an app's data container on the phone, creating its folders.
    func write(_ data: Data, to path: String, of bundleID: String, on udid: String) -> Bool {
        let file = FileManager.default.temporaryDirectory.appending(path: "redline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try data.write(to: file)
        } catch {
            return false
        }
        return (try? Self.run(executable, arguments: [
            "device", "copy", "to", "--device", udid, "--domain-type", "appDataContainer",
            "--domain-identifier", bundleID, "--source", file.path, "--destination", path, "--quiet",
        ]))?.status == 0
    }

    /// Runs devicectl and decodes the JSON it writes. Throws when it can't start, fails, or
    /// writes something that doesn't decode.
    private func runJSON<T: Decodable>(_ arguments: [String]) throws -> T {
        let file = FileManager.default.temporaryDirectory.appending(path: "redline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try Self.run(executable, arguments: arguments + ["--json-output", file.path, "--quiet"])
        guard result.status == 0 else { throw DevicectlError.failed(status: result.status) }
        return try Self.decoder.decode(T.self, from: Data(contentsOf: file))
    }

    private static let decoder = JSONDecoder()

    enum DevicectlError: Error {
        case failed(status: Int32)
    }

    /// Runs a command and returns its exit status and standard output. Throws when it can't start.
    static func run(_ executable: URL, arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
#endif
