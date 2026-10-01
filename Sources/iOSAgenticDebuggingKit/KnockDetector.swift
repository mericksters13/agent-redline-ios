#if AGENTIC_DEBUGGING
import Foundation

/// One motion reading: user acceleration in g along the device axes, where z
/// points out of the screen toward the user, and the rotation rate in rad/s.
struct MotionSample: Sendable {
    var time: TimeInterval
    var x: Double
    var y: Double
    var z: Double
    var rotationRate: Double
}

/// Finds two quick knocks on the back of the phone in a stream of motion samples.
///
/// A knock on the back pushes the phone toward the user, so it shows up as a
/// short positive spike on the z axis. Taps on the screen push the other way and
/// are ignored, as are spikes while the phone is moving or turning.
struct KnockDetector: Sendable {
    struct Configuration: Sendable, Equatable {
        /// Minimum z acceleration, in g, that counts as a knock.
        var threshold = 0.25
        /// The z spike must be at least this many times the sideways acceleration.
        var dominance = 1.5
        /// Rotation faster than this, in rad/s, means the phone is being handled.
        var maxRotationRate = 1.5
        /// Average motion between knocks above this, in g, means the phone is moving.
        var maxBackgroundMotion = 0.08
        /// Samples this soon after a knock belong to the same knock.
        var ringTime: TimeInterval = 0.07
        /// The second knock must land within this long after the first.
        var maxGap: TimeInterval = 0.45
        /// Nothing counts for this long after a double knock.
        var cooldown: TimeInterval = 0.8
    }

    enum Event: Equatable, Sendable {
        case knock(strength: Double)
        case doubleKnock
    }

    var configuration: Configuration
    /// Average motion between knocks, in g.
    private(set) var backgroundMotion = 0.0
    private var firstKnockTime: TimeInterval?
    private var lastKnockTime = -Double.infinity
    private var lastDoubleKnockTime = -Double.infinity

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func process(_ sample: MotionSample) -> Event? {
        let settings = configuration
        if sample.time - lastKnockTime < settings.ringTime { return nil }

        let side = (sample.x * sample.x + sample.y * sample.y).squareRoot()
        let isSpike = sample.z >= settings.threshold && sample.z >= side * settings.dominance
        guard isSpike else {
            let magnitude = (side * side + sample.z * sample.z).squareRoot()
            backgroundMotion += (magnitude - backgroundMotion) * 0.05
            return nil
        }
        guard sample.time - lastDoubleKnockTime >= settings.cooldown,
              sample.rotationRate <= settings.maxRotationRate,
              backgroundMotion <= settings.maxBackgroundMotion
        else { return nil }

        lastKnockTime = sample.time
        if let first = firstKnockTime, sample.time - first <= settings.maxGap {
            firstKnockTime = nil
            lastDoubleKnockTime = sample.time
            return .doubleKnock
        }
        firstKnockTime = sample.time
        return .knock(strength: sample.z)
    }
}
#endif
