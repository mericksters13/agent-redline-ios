#if AGENTIC_DEBUGGING
import Foundation
import Testing
@testable import iOSAgenticDebuggingKit

struct BuildIdentityTests {
    @Test func theRunningBuildHasAnID() {
        let ids = BuildIdentity.ids()
        #expect(!ids.isEmpty)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
    }
}
#endif
