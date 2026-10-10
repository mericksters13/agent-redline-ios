#if os(macOS)
import Darwin
import Foundation

/// Read-only command probes used by setup and doctor.
///
/// Does not use shell interpolation or print command output.
enum CommandOutput {
    /// Captures at most 64 KiB while the child runs.
    ///
    /// A failed or timed-out probe returns nil.
    /// Blocking: used from synchronous CLI commands or the existing Claude readiness check queue.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval = 10,
        environment: [String: String]? = nil
    ) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        defer { try? pipe.fileHandleForReading.close() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // No separate reader is left waiting on a pipe inherited by a descendant of the child.
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            // A child flooding stdout cannot keep us here past the timeout.
            for _ in 0..<16 {
                let count = read(descriptor, &bytes, bytes.count)
                guard count > 0 else { return }
                let kept = min(count, max(65_536 - output.count, 0))
                output.append(contentsOf: bytes.prefix(kept))
            }
        }
        let deadline = ContinuousClock.now + .milliseconds(Int(max(timeout, 0) * 1000))
        while true {
            drain()
            if exited.wait(timeout: .now() + 0.01) == .success { break }
            if ContinuousClock.now >= deadline {
                process.terminate()
                if exited.wait(timeout: .now() + 0.2) != .success, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 0.2)
                }
                return nil
            }
        }
        drain()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
#endif
