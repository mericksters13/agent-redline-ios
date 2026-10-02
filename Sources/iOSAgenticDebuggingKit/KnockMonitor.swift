#if AGENTIC_DEBUGGING && canImport(UIKit)
import CoreMotion
import Foundation
import Synchronization

/// Feeds device motion into a `KnockDetector` on a background queue and throws
/// out double knocks that coincide with a screen touch.
final class KnockMonitor: @unchecked Sendable {
    enum Output: Sendable {
        case doubleKnock
        case knock(strength: Double)
        /// A double knock with a screen touch around it: a double tap, not a knock on the back.
        case ignoredScreenTap
        /// Peak z acceleration over the last tenth of a second and the background
        /// motion, both in g. Sent only when the readout is on.
        case levels(peak: Double, background: Double)
    }

    // `detector`, `peak`, `sampleCount` and `impulseStart` are touched only on `queue`.
    private let manager = CMMotionManager()
    private let queue = DispatchQueue(label: "iOSAgenticDebuggingKit.knock", qos: .userInteractive)
    private let operationQueue = OperationQueue()
    private let touches = Mutex(TouchLog())
    private var detector: KnockDetector
    private var peak = 0.0
    private var sampleCount = 0
    private var impulseStart = -Double.infinity
    private let isTuning: Bool
    private let output: @Sendable (Output) -> Void

    /// With `isTuning` on, the monitor reports motion levels and prints every
    /// jolt to the console so thresholds can be tuned on a real phone.
    init(configuration: KnockDetector.Configuration, isTuning: Bool, output: @escaping @Sendable (Output) -> Void) {
        detector = KnockDetector(configuration: configuration)
        self.isTuning = isTuning
        self.output = output
        operationQueue.underlyingQueue = queue
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100.0
        manager.startDeviceMotionUpdates(to: operationQueue) { [weak self] motion, _ in
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

    /// Called for every touch on the screen, with the event's timestamp.
    func recordTouch(at time: TimeInterval) {
        touches.withLock { $0.record(time) }
    }

    private func handle(_ sample: MotionSample) {
        switch detector.process(sample) {
        case .doubleKnock(let first, let second):
            // Wait out the margin so a touch event that arrives after the motion still counts.
            queue.asyncAfter(deadline: .now() + TouchLog.margin) { [weak self] in
                guard let self else { return }
                let tapped = self.touches.withLock { $0.hasTouch(around: first, second) }
                if self.isTuning {
                    print("[iOSAgenticDebuggingKit] double knock \(tapped ? "ignored: screen touched" : "accepted")")
                }
                self.output(tapped ? .ignoredScreenTap : .doubleKnock)
            }
        case .knock(let strength):
            output(.knock(strength: strength))
        case nil:
            break
        }

        guard isTuning else { return }
        if abs(sample.z) > 0.15, sample.time - impulseStart > 0.08 {
            impulseStart = sample.time
            print(String(
                format: "[iOSAgenticDebuggingKit] jolt t=%.3f z=%+.2f x=%+.2f y=%+.2f rotation=%.2f background=%.3f",
                sample.time, sample.z, sample.x, sample.y, sample.rotationRate, detector.backgroundMotion
            ))
        }
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
