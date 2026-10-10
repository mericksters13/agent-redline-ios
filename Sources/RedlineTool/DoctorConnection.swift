#if os(macOS)
import Darwin
import Foundation

/// The running hub checks access in its own process, rather than borrowing Terminal's permissions.
final class DoctorConnection: @unchecked Sendable {
    struct Request: Codable, Sendable {
        var id = UUID()
        var project: String
        var agent: String
    }

    struct Reply: Codable, Sendable {
        var id: UUID
        var pid: Int32
        var isMacApp: Bool
        var checks: [Doctor.Check]
    }

    private let source: any DispatchSourceRead
    private let clients = DispatchQueue(label: "Redline.doctor.clients", qos: .utility)
    private let handle: @Sendable (Request) -> Reply

    private init(source: any DispatchSourceRead, handle: @escaping @Sendable (Request) -> Reply) {
        self.source = source
        self.handle = handle
    }

    private static func socketFile(_ paths: HubPaths) -> URL {
        paths.hub.appending(path: "doctor/socket")
    }

    static func start(paths: HubPaths, handle: @escaping @Sendable (Request) -> Reply) -> DoctorConnection? {
        let file = socketFile(paths)
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch { return nil }
        guard var address = address(file.path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(file.path, 0o600) == 0, listen(descriptor, 4) == 0,
            fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
        else {
            close(descriptor)
            return nil
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "Redline.doctor.socket", qos: .utility)
        )
        let server = DoctorConnection(source: source, handle: handle)
        source.setEventHandler { [weak server] in
            while let server {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { break }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    close(client)
                    continue
                }
                server.clients.async {
                    defer { close(client) }
                    Self.configure(client, timeout: 2)
                    guard let data = Self.read(client, timeout: 2),
                        let request = try? JSONDecoder().decode(Request.self, from: data),
                        request.project.utf8.count < 4096,
                        request.agent == "auto" || Agent(rawValue: request.agent) != nil
                    else { return }
                    let reply = server.handle(request)
                    guard let output = try? JSONEncoder().encode(reply) else { return }
                    _ = Self.send(output, to: client)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return server
    }

    func stop() { source.cancel() }

    deinit { source.cancel() }

    /// A bounded, same-user local request; no configuration or report files are changed by the CLI.
    static func query(_ request: Request, paths: HubPaths) -> Reply? {
        guard let descriptor = UnixSocket.connect(path: socketFile(paths).path) else { return nil }
        defer { close(descriptor) }
        configure(descriptor, timeout: 12)
        guard let data = try? JSONEncoder().encode(request), send(data, to: descriptor),
            let output = read(descriptor, timeout: 12)
        else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: output)
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func configure(_ descriptor: Int32, timeout: Int) {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
        var value = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func read(_ descriptor: Int32, timeout: TimeInterval) -> Data? {
        var data = Data()
        let deadline = Date.now.addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 65_536 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var wait = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - floor(remaining)) * 1_000_000))
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65_536 else { return nil }
            if let end = data.firstIndex(of: UInt8(ascii: "\n")) { return data.prefix(upTo: end) }
        }
        return nil
    }

    private static func send(_ data: Data, to descriptor: Int32) -> Bool {
        var message = data
        message.append(UInt8(ascii: "\n"))
        return message.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress?.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}
#endif
