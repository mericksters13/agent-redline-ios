#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct LineBufferTests {
    @Test func linesComeOutWholeHoweverTheyArrive() {
        var buffer = LineBuffer()
        buffer.append(Data("first\nsec".utf8))
        #expect(buffer.takeLine() == Data("first".utf8))
        #expect(buffer.takeLine() == nil)
        buffer.append(Data("ond\n\nthird".utf8))
        #expect(buffer.takeLine() == Data("second".utf8))
        #expect(buffer.takeLine() == Data())
        #expect(buffer.takeLine() == nil)
        #expect(buffer.count == 5)
    }

    /// A long line in small pieces, the way a big report arrives over TCP.
    private func secondsToRead(megabytes: Int) -> TimeInterval {
        var buffer = LineBuffer()
        let piece = Data(repeating: UInt8(ascii: "a"), count: 16_384)
        let started = Date.now
        for _ in 0..<(megabytes * 64) {
            buffer.append(piece)
            _ = buffer.takeLine()
        }
        buffer.append(Data("\n".utf8))
        #expect(buffer.takeLine()?.count == megabytes * 1_048_576)
        return Date.now.timeIntervalSince(started)
    }

    @Test func aLongLineTakesTimeInProportionToItsLength() {
        // Searching the whole buffer after every piece took minutes for a line this long.
        let twenty = secondsToRead(megabytes: 20)
        #expect(twenty < 5)
        let forty = secondsToRead(megabytes: 40)
        #expect(forty < twenty * 4 + 0.5)
    }

    @Test func aTimeoutResumesOnlyWhenNothingElseDid() async {
        let once = Once<Int>()
        let timedOut = await withCheckedContinuation { continuation in
            once.set(continuation)
            once.timeout(after: 0.05, on: .global(), with: 0)
        }
        #expect(timedOut == 0)

        let first = Once<Int>()
        let resumed = await withCheckedContinuation { continuation in
            first.set(continuation)
            first.timeout(after: 0.05, on: .global(), with: 0)
            first.resume(1)
        }
        #expect(resumed == 1)
        // The cancelled timeout doesn't fire later, and a second resume does nothing.
        first.resume(2)
    }
}
#endif
