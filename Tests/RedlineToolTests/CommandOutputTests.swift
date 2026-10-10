#if os(macOS)
import Foundation
import Testing
@testable import RedlineTool

struct CommandOutputTests {
    @Test func successfulOutputIsCappedAndFailureOutputIsNotReturned() async {
        let output = await offPool { CommandOutput.run(URL(filePath: "/usr/bin/printf"), ["ready"]) }
        #expect(output == "ready")
        let failed = await offPool { CommandOutput.run(URL(filePath: "/bin/sh"), ["-c", "echo private; exit 1"]) }
        #expect(failed == nil)
        let long = await offPool {
            CommandOutput.run(URL(filePath: "/bin/sh"), ["-c", "yes x | head -c 100000"])
        }
        #expect(long?.utf8.count == 65_536)
    }

    @Test func aChildIgnoringTerminationIsKilledWithinTheTimeoutGracePeriod() async {
        let started = ContinuousClock.now
        let output = await offPool {
            CommandOutput.run(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.1)
        }
        #expect(output == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
    }
}
#endif
