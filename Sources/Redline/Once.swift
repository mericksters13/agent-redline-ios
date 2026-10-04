#if REDLINE
import Synchronization

/// Resumes a continuation once, whichever of several callbacks comes first: a reply, a
/// timeout or a cancellation.
final class Once<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Never>?
        /// Resumes with a fallback value when time runs out.
        ///
        /// Cancelled once resumed.
        var timeout: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func set(_ continuation: CheckedContinuation<T, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// Resumes with `value` once `delay` passes, unless something resumes it first.
    ///
    /// The timer stops as soon as it is resumed, so a finished wait leaves nothing behind.
    func resume(_ value: T, after delay: Duration) {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resume(value)
        }
        let isWaiting = state.withLock { state in
            guard state.continuation != nil else { return false }
            state.timeout = timeout
            return true
        }
        if !isWaiting { timeout.cancel() }
    }

    func resume(_ value: T) {
        let (waiting, timeout) = state.withLock { state in
            defer { state = State() }
            return (state.continuation, state.timeout)
        }
        timeout?.cancel()
        // Resumed outside the lock, so the waiting task never starts while it is held.
        waiting?.resume(returning: value)
    }
}
#endif
