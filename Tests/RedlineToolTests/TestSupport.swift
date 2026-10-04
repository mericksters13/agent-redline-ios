#if os(macOS)
import Foundation

/// Runs blocking code, such as a wait on a semaphore or a child process, on a Dispatch thread,
/// so a test never parks a thread of the cooperative pool.
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}
#endif
