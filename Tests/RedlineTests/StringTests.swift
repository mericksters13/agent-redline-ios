#if REDLINE
import Testing
@testable import Redline

struct StringTests {
    @Test func aCountTakesTheRightNoun() {
        #expect(countPhrase(0, singular: "note", plural: "notes") == "0 notes")
        #expect(countPhrase(1, singular: "note", plural: "notes") == "1 note")
        #expect(countPhrase(3, singular: "screen", plural: "screens") == "3 screens")
    }

    @Test func anEmptyStringIsNoValue() {
        #expect("".nonEmpty == nil)
        #expect("Save".nonEmpty == "Save")
    }
}
#endif
