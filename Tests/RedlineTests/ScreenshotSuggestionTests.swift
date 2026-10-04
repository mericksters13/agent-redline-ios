#if REDLINE
import Foundation
import Testing
@testable import Redline

struct ScreenshotSuggestionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func shot(_ id: String, minutesAgo: Double) -> ScreenshotSuggestion.Candidate {
        .init(id: id, createdAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func aRecentScreenshotIsOffered() {
        let picked = ScreenshotSuggestion.candidateToOffer(
            among: [shot("a", minutesAgo: 2)],
            now: now,
            offered: [],
            inAppCaptures: []
        )
        #expect(picked?.id == "a")
    }

    @Test func onlyTheNewestCounts() {
        let shots = [shot("old", minutesAgo: 5), shot("new", minutesAgo: 1)]
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: shots, now: now, offered: [], inAppCaptures: [])?.id == "new"
        )
        // Once the newest has been offered, an older one never turns up.
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: shots, now: now, offered: ["new"], inAppCaptures: []) == nil
        )
    }

    @Test func screenshotsOlderThanTenMinutesAreLeftAlone() {
        #expect(
            ScreenshotSuggestion.candidateToOffer(
                among: [shot("a", minutesAgo: 11)],
                now: now,
                offered: [],
                inAppCaptures: []
            ) == nil
        )
    }

    @Test func aScreenshotTheAppAlreadyCapturedIsNotOfferedTwice() {
        let taken = shot("a", minutesAgo: 1)
        let captured = taken.createdAt.addingTimeInterval(0.8)
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: [taken], now: now, offered: [], inAppCaptures: [captured])
                == nil
        )
        let earlier = taken.createdAt.addingTimeInterval(-60)
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: [taken], now: now, offered: [], inAppCaptures: [earlier])?.id
                == "a"
        )
    }

    @Test func nothingToOfferWhenThereAreNoScreenshots() {
        #expect(ScreenshotSuggestion.candidateToOffer(among: [], now: now, offered: [], inAppCaptures: []) == nil)
    }
}
#endif
