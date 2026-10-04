#if REDLINE
import os

/// Where the kit logs, one category per area.
///
/// Everything the kit logs goes through these.
enum Log {
    /// Every category shares this subsystem, so Console can show all of Redline at once.
    static let subsystem = "io.github.mericksters13.redline"

    static let session = Logger(subsystem: subsystem, category: "session")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let hubLink = Logger(subsystem: subsystem, category: "hub-link")
    static let report = Logger(subsystem: subsystem, category: "report")
    static let photos = Logger(subsystem: subsystem, category: "photos")
    static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
}
#endif
