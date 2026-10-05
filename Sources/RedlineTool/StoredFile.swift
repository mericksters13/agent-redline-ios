#if os(macOS)
import Foundation

/// Reading the hub's own files, where a missing file is normal and any other failure isn't.
enum StoredFile {
    /// The file's contents, or nil when it doesn't exist.
    ///
    /// Any other failure, such as a file the user can't read, throws, so it's never mistaken for an
    /// empty one and written over.
    static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// Moves a file that can't be read or decoded out of the way, so starting fresh doesn't write
    /// over what might still be recovered.
    ///
    /// The name follows the kit's: `state.json` becomes `state-unreadable-20261003-215826.json`.
    ///
    /// Returns where it went, or nil when it couldn't be moved.
    @discardableResult
    static func moveAside(_ url: URL, at date: Date = .now) -> URL? {
        let name =
            "\(url.deletingPathExtension().lastPathComponent)-unreadable-\(timestampFormatter.string(from: date))"
        let aside = url.deletingLastPathComponent().appending(path: name).appendingPathExtension(url.pathExtension)
        return (try? FileManager.default.moveItem(at: url, to: aside)) == nil ? nil : aside
    }

    /// Names set-aside files by when they were moved, such as 20261003-215826, as the kit does.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// The decoded file; nil when it doesn't exist.
    ///
    /// A file that can't be read or decoded is moved aside, with `report` told why, and treated as
    /// missing.
    static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder, report: (String) -> Void) -> T?
    {
        do {
            guard let data = try read(url) else { return nil }
            return try decoder.decode(type, from: data)
        } catch {
            let aside = moveAside(url)
            report(
                "Couldn't read \(url.path): \(error.localizedDescription). \(aside.map { "Moved it to \($0.lastPathComponent); starting fresh" } ?? "Starting fresh")."
            )
            return nil
        }
    }
}
#endif
