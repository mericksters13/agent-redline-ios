#if os(macOS)
import Foundation
import Synchronization

/// Resumes a continuation once, whichever of several callbacks comes first, and cancels its
/// timeout when it does.
final class Once<T: Sendable>: Sendable {
    private struct Waiting {
        var continuation: CheckedContinuation<T, Never>?
        var timeout: DispatchWorkItem?
    }

    private let waiting = Mutex(Waiting())

    func set(_ continuation: CheckedContinuation<T, Never>) {
        waiting.withLock { $0.continuation = continuation }
    }

    /// Resumes with `value` after `seconds`, unless something resumes first.
    ///
    /// Called again, it replaces the timeout before, so the wait starts over.
    func timeout(after seconds: TimeInterval, on queue: DispatchQueue, with value: T) {
        waiting.withLock { waiting in
            guard waiting.continuation != nil else { return }
            waiting.timeout?.cancel()
            let item = DispatchWorkItem { self.resume(value) }
            waiting.timeout = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    func resume(_ value: T) {
        let waiting = waiting.withLock { waiting in
            defer { waiting = Waiting() }
            return waiting
        }
        waiting.timeout?.cancel()
        waiting.continuation?.resume(returning: value)
    }
}
#endif
