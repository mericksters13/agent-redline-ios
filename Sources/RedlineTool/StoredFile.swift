#if os(macOS)
import Foundation

/// Reading the hub's own files, where a missing file is normal and any other failure isn't.
enum StoredFile {
    /// The file's contents, or nil when it doesn't exist. Any other failure, such as a file the
    /// user can't read, throws, so it's never mistaken for an empty one and written over.
    static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// Moves a file that can't be read or decoded out of the way, so starting fresh doesn't
    /// write over what might still be recovered. Returns where it went.
    @discardableResult
    static func moveAside(_ url: URL) -> URL? {
        let stamp = Date.now.formatted(.iso8601).replacing(":", with: "-")
        let aside = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).unreadable-\(stamp)")
        return (try? FileManager.default.moveItem(at: url, to: aside)) == nil ? nil : aside
    }

    /// The decoded file; nil when it doesn't exist. A file that can't be read or decoded is
    /// moved aside, with `report` told why, and treated as missing.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder, report: (String) -> Void) -> T? {
        do {
            guard let data = try read(url) else { return nil }
            return try decoder.decode(type, from: data)
        } catch {
            let aside = moveAside(url)
            report("Couldn't read \(url.path): \(error.localizedDescription). \(aside.map { "Moved it to \($0.lastPathComponent); starting fresh" } ?? "Starting fresh").")
            return nil
        }
    }
}
#endif
