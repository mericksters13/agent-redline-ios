#if REDLINE
import Foundation

extension String {
    /// The string, or nil when it's empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A count with its noun, such as "1 note" or "3 notes".
func countPhrase(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(plural)"
}
#endif
