#if os(macOS)
import Foundation

/// The bytes read from a connection, taken a line at a time.
///
/// Each byte is looked at once for a newline, however many pieces a long line arrives in.
struct LineBuffer {
    private var bytes = Data()
    /// How far the search for a newline has got.
    private var scanned = 0

    var count: Int { bytes.count }

    mutating func append(_ data: Data) {
        bytes.append(data)
    }

    /// The next line, without its newline; nil until one is complete.
    mutating func takeLine() -> Data? {
        guard let newline = bytes[(bytes.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) else {
            scanned = bytes.count
            return nil
        }
        let line = Data(bytes[bytes.startIndex..<newline])
        bytes = Data(bytes[(newline + 1)...])
        scanned = 0
        return line
    }
}
#endif
