#if os(macOS)
import Darwin
import Foundation

/// Connecting to a local app's Unix socket, as the Claude Code chats and the Codex app offer.
enum UnixSocket {
    /// A connected socket, or nil when nothing listens at `path`.
    ///
    /// Writing after the other end closes fails with an error instead of ending this process with
    /// SIGPIPE.
    static func connect(path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyMemory(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }
}
#endif
