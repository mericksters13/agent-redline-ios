#if AGENTIC_DEBUGGING
import Foundation
import Testing
@testable import iOSAgenticDebuggingKit

struct KnockDetectorTests {
    /// 100 Hz samples of a phone lying still, with a little sensor noise.
    private func still(from start: TimeInterval, to end: TimeInterval) -> [MotionSample] {
        stride(from: start, to: end, by: 0.01).enumerated().map { index, time in
            let noise = index.isMultiple(of: 2) ? 0.01 : -0.01
            return MotionSample(time: time, x: noise, y: -noise, z: noise, rotationRate: 0.02)
        }
    }

    private func knock(at time: TimeInterval, z: Double = 0.5) -> MotionSample {
        MotionSample(time: time, x: 0.05, y: 0.05, z: z, rotationRate: 0.1)
    }

    private func events(_ samples: [MotionSample]) -> [KnockDetector.Event] {
        var detector = KnockDetector()
        return samples.compactMap { detector.process($0) }
    }

    @Test func twoKnocksCloseTogetherAreADoubleKnock() {
        let samples = still(from: 0, to: 1) + [knock(at: 1.0)] + still(from: 1.01, to: 1.25) + [knock(at: 1.25)]
        #expect(events(samples) == [.knock(strength: 0.5), .doubleKnock])
    }

    @Test func oneKnockIsNotADoubleKnock() {
        let samples = still(from: 0, to: 1) + [knock(at: 1.0)] + still(from: 1.01, to: 2)
        #expect(events(samples) == [.knock(strength: 0.5)])
    }

    @Test func knocksTooFarApartStartOver() {
        let samples = still(from: 0, to: 1) + [knock(at: 1.0)] + still(from: 1.01, to: 1.8) + [knock(at: 1.8)]
        #expect(events(samples) == [.knock(strength: 0.5), .knock(strength: 0.5)])
    }

    @Test func ringingAfterAKnockCountsOnce() {
        let ring = [knock(at: 1.01, z: 0.4), knock(at: 1.03, z: 0.3)]
        let samples = still(from: 0, to: 1) + [knock(at: 1.0)] + ring + still(from: 1.08, to: 2)
        #expect(events(samples) == [.knock(strength: 0.5)])
    }

    @Test func screenTapsPushTheOtherWayAndAreIgnored() {
        let samples = still(from: 0, to: 1) + [knock(at: 1.0, z: -0.6)] + still(from: 1.01, to: 1.25) + [knock(at: 1.25, z: -0.6)]
        #expect(events(samples).isEmpty)
    }

    @Test func sidewaysJoltsAreIgnored() {
        let jolt = MotionSample(time: 1.0, x: 0.6, y: 0.2, z: 0.3, rotationRate: 0.1)
        let samples = still(from: 0, to: 1) + [jolt]
        #expect(events(samples).isEmpty)
    }

    @Test func knocksWhileWalkingAreIgnored() {
        let walking = stride(from: 0.0, to: 2.0, by: 0.01).map { time in
            MotionSample(time: time, x: 0.15 * sin(time * 12), y: 0.2 * cos(time * 12), z: 0.1 * sin(time * 6), rotationRate: 0.4)
        }
        let samples = walking + [knock(at: 2.0)] + [knock(at: 2.25)]
        #expect(events(samples).isEmpty)
    }

    @Test func knocksWhileTurningThePhoneAreIgnored() {
        let turning = [
            MotionSample(time: 1.0, x: 0, y: 0, z: 0.5, rotationRate: 3),
            MotionSample(time: 1.25, x: 0, y: 0, z: 0.5, rotationRate: 3),
        ]
        #expect(events(still(from: 0, to: 1) + turning).isEmpty)
    }

    @Test func nothingCountsRightAfterADoubleKnock() {
        var samples = still(from: 0, to: 1) + [knock(at: 1.0)] + still(from: 1.01, to: 1.25) + [knock(at: 1.25)]
        samples += still(from: 1.26, to: 1.5) + [knock(at: 1.5)] + still(from: 1.51, to: 1.7) + [knock(at: 1.7)]
        #expect(events(samples) == [.knock(strength: 0.5), .doubleKnock])
    }

    @Test func thresholdIsConfigurable() {
        var detector = KnockDetector(configuration: .init(threshold: 0.6))
        let samples = still(from: 0, to: 1) + [knock(at: 1.0)] + still(from: 1.01, to: 1.25) + [knock(at: 1.25)]
        #expect(samples.compactMap { detector.process($0) }.isEmpty)
    }
}
#endif
