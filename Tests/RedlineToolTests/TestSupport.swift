#if os(macOS)
import Foundation
@testable import RedlineTool

/// Runs blocking code, such as a wait on a semaphore or a child process, on a Dispatch thread,
/// so a test never parks a thread of the cooperative pool.
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}

/// The same, for code that throws.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
}

/// A folder of its own for one test, removed when the test's suite value goes away.
final class TemporaryFolder: Sendable {
    let url: URL

    init(_ name: String) {
        url = FileManager.default.temporaryDirectory.appending(
            path: "\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Runs a command and returns what it printed, off the cooperative pool.
@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) async throws -> String {
    try await offPool {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}

/// JSON with sorted keys, for comparing dictionaries.
func sortedJSON(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

/// Files a report in the inbox the way the hub does: filled under a hidden name, then renamed into
/// place whole.
///
/// Returns its folder.
@discardableResult
func fileInboxReport(
    _ name: String,
    bundleID: String = "com.example.app",
    in paths: HubPaths,
    listing: [String: Any],
    snapshots: [String: Data] = ["screen-1.jpg": Data([0xFF, 0xD8])],
    summary: String? = nil,
    deviceName: String = "Test iPhone",
    receivedAt: Date = .now,
    recipient: ReportRecipient? = nil
) throws -> URL {
    let incoming = paths.inbox.appending(
        path: "\(bundleID)/\(Inbox.incomingPrefix)\(name)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    if let summary { try summary.write(to: incoming.appending(path: "report.md"), atomically: true, encoding: .utf8) }
    try JSONSerialization.data(withJSONObject: listing).write(to: incoming.appending(path: "report.json"))
    for (file, data) in snapshots { try data.write(to: incoming.appending(path: file)) }
    let reportID = String(name.prefix(15))
    let source = ReportSource(
        kind: .phone,
        device: "00000000-0000000000000001",
        deviceName: deviceName,
        bundleID: bundleID,
        reportID: reportID,
        receivedAt: receivedAt
    )
    try HubPaths.encoder.encode(source).write(to: incoming.appending(path: Inbox.sourceFile))
    if let recipient { try Inbox.setRecipient(recipient, of: incoming) }
    let folder = paths.inbox.appending(path: "\(bundleID)/\(name)", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: incoming, to: folder)
    return folder
}
#endif
