#if AGENTIC_DEBUGGING && canImport(UIKit)
import CoreMotion
import Foundation

/// Feeds device motion into a `KnockDetector` on a background queue.
final class KnockMonitor: @unchecked Sendable {
    enum Output: Sendable {
        case detector(KnockDetector.Event)
        /// Peak z acceleration over the last tenth of a second and the background
        /// motion, both in g. Sent only when the readout is on.
        case levels(peak: Double, background: Double)
    }

    // `detector`, `peak` and `sampleCount` are touched only on `queue`.
    private let manager = CMMotionManager()
    private let queue: OperationQueue
    private var detector: KnockDetector
    private var peak = 0.0
    private var sampleCount = 0
    private let reportsLevels: Bool
    private let output: @Sendable (Output) -> Void

    init(configuration: KnockDetector.Configuration, reportsLevels: Bool, output: @escaping @Sendable (Output) -> Void) {
        detector = KnockDetector(configuration: configuration)
        self.reportsLevels = reportsLevels
        self.output = output
        queue = OperationQueue()
        queue.name = "iOSAgenticDebuggingKit.knock"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let rotation = motion.rotationRate
            self.handle(MotionSample(
                time: motion.timestamp,
                x: motion.userAcceleration.x,
                y: motion.userAcceleration.y,
                z: motion.userAcceleration.z,
                rotationRate: (rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z).squareRoot()
            ))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func handle(_ sample: MotionSample) {
        if let event = detector.process(sample) {
            output(.detector(event))
        }
        guard reportsLevels else { return }
        peak = max(peak, sample.z)
        sampleCount += 1
        if sampleCount == 10 {
            output(.levels(peak: peak, background: detector.backgroundMotion))
            peak = 0
            sampleCount = 0
        }
    }
}
#endif
