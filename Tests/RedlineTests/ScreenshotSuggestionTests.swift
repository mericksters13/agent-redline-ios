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
            handledCaptures: []
        )
        #expect(picked?.id == "a")
    }

    @Test func onlyTheNewestCounts() {
        let shots = [shot("old", minutesAgo: 5), shot("new", minutesAgo: 1)]
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: shots, now: now, offered: [], handledCaptures: [])?.id == "new"
        )
        // Once the newest has been offered, an older one never turns up.
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: shots, now: now, offered: ["new"], handledCaptures: []) == nil
        )
    }

    @Test func screenshotsOlderThanTenMinutesAreLeftAlone() {
        #expect(
            ScreenshotSuggestion.candidateToOffer(
                among: [shot("a", minutesAgo: 11)],
                now: now,
                offered: [],
                handledCaptures: []
            ) == nil
        )
    }

    @Test func theCopyOfACaptureAlreadySentOrClosedIsNotOffered() {
        let taken = shot("a", minutesAgo: 1)
        let captured = taken.createdAt.addingTimeInterval(0.8)
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: [taken], now: now, offered: [], handledCaptures: [captured])
                == nil
        )
        let earlier = taken.createdAt.addingTimeInterval(-60)
        #expect(
            ScreenshotSuggestion.candidateToOffer(among: [taken], now: now, offered: [], handledCaptures: [earlier])?
                .id == "a"
        )
    }

    @Test func theSavedCopyTakesTheAppsOwnCapturesPlace() {
        let captured = now.addingTimeInterval(-60)
        // The system dates its copy at the screenshot, a moment before the app's capture.
        #expect(ScreenshotSuggestion.replaces(captureAt: captured, .init(id: "a", createdAt: captured - 0.8)))
        // Saved after a long edit, or a newer screenshot altogether.
        #expect(ScreenshotSuggestion.replaces(captureAt: captured, .init(id: "b", createdAt: captured + 45)))
        // One from before the capture is some other screenshot.
        #expect(!ScreenshotSuggestion.replaces(captureAt: captured, .init(id: "c", createdAt: captured - 30)))
    }

    @Test func nothingToOfferWhenThereAreNoScreenshots() {
        #expect(ScreenshotSuggestion.candidateToOffer(among: [], now: now, offered: [], handledCaptures: []) == nil)
    }
}
#endif
