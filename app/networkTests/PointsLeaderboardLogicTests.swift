import Foundation
import Testing
@testable import URnetwork

struct PointsLeaderboardLogicTests {

    @Test func loadMoreOnlyNearTheEndOfALoadedList() {
        // 50 rows, threshold 10: rows 39 and up ask for more
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 20, rowCount: 50, isLoading: false, isEndReached: false, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 38, rowCount: 50, isLoading: false, isEndReached: false, hasError: false))
        #expect(PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 39, rowCount: 50, isLoading: false, isEndReached: false, hasError: false))
        #expect(PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: false, isEndReached: false, hasError: false))
    }

    @Test func loadMoreNeverAsksWhileLoadingAtTheEndOrWithNothingVisible() {
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: true, isEndReached: false, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: false, isEndReached: true, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: -1, rowCount: 50, isLoading: false, isEndReached: false, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 0, rowCount: 0, isLoading: false, isEndReached: false, hasError: false))
    }

    @Test func loadMoreWaitsForRetryAfterAFailedPage() {
        // a failed page leaves loading false and the error set: only the
        // footer's Retry may ask again, never the scroll trigger
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: false, isEndReached: false, hasError: true))
        #expect(PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: false, isEndReached: false, hasError: false))
    }

    @Test func validationReasonsMapToEditorErrors() {
        #expect(EmojiTagEditor.errorFor(ok: true, reason: "") == nil)
        #expect(EmojiTagEditor.errorFor(ok: false, reason: "empty") == .empty)
        #expect(EmojiTagEditor.errorFor(ok: false, reason: "too_many") == .tooMany)
        #expect(EmojiTagEditor.errorFor(ok: false, reason: "not_emoji") == .notEmoji)
        // an unknown reason from a newer sdk still reads as "not emoji"
        #expect(EmojiTagEditor.errorFor(ok: false, reason: "something_else") == .notEmoji)
        #expect(EmojiTagEditor.errorFor(ok: false, reason: nil) == .notEmoji)
    }

    @Test func saveNeedsAValidChangedTag() {
        #expect(EmojiTagEditor.canSave(ok: true, normalized: "🐬🔥", currentTag: "", isSaving: false))
        #expect(!EmojiTagEditor.canSave(ok: true, normalized: "🐬🔥", currentTag: "🐬🔥", isSaving: false))
        #expect(!EmojiTagEditor.canSave(ok: true, normalized: "🐬🔥", currentTag: "", isSaving: true))
        #expect(!EmojiTagEditor.canSave(ok: false, normalized: "", currentTag: "", isSaving: false))
        #expect(!EmojiTagEditor.canSave(ok: true, normalized: "", currentTag: "🐬", isSaving: false))
    }

    @Test func anEmptyDraftIsNotAnErrorWhileEditing() {
        #expect(!EmojiTagEditor.showsError(text: "", error: .empty))
        #expect(EmojiTagEditor.showsError(text: "a", error: .notEmoji))
        #expect(EmojiTagEditor.showsError(text: "🐬🐬🐬🐬🐬🐬🐬", error: .tooMany))
        #expect(!EmojiTagEditor.showsError(text: "🐬", error: nil))
    }

    @Test func backspaceRemovesOneWholeEmoji() {
        #expect(EmojiTagEditor.dropLastEmoji("") == "")
        #expect(EmojiTagEditor.dropLastEmoji("🐬") == "")
        #expect(EmojiTagEditor.dropLastEmoji("🐬🔥") == "🐬")
        // a skin-toned hand, a flag pair and a ZWJ family each go as ONE emoji
        #expect(EmojiTagEditor.dropLastEmoji("🐬👍🏽") == "🐬")
        #expect(EmojiTagEditor.dropLastEmoji("🐬🇯🇵") == "🐬")
        #expect(EmojiTagEditor.dropLastEmoji("🐬👨‍👩‍👧") == "🐬")
    }

    @Test func theEmojiKeyboardOnlyOffersSingleEmoji() {
        for section in EmojiKeyboardCatalog.sections {
            #expect(!section.emoji.isEmpty)
            for emoji in section.emoji {
                // exactly one grapheme cluster, and never plain text
                #expect(emoji.count == 1, "\(emoji) in \(section.id) is not one emoji")
                #expect(emoji.unicodeScalars.first?.properties.isEmoji == true, "\(emoji) is not an emoji")
            }
        }
        let all = EmojiKeyboardCatalog.sections.flatMap { $0.emoji }
        #expect(Set(all).count == all.count, "the keyboard repeats an emoji")
    }

    // MARK: backward paging

    @Test func loadBeforeOnlyWhenTheFirstLoadedRowShowsWithRanksAboveIt() {
        // window 200...249 with ranks above: the first loaded row asks, others do not
        #expect(PointsLeaderboardPaging.shouldLoadBefore(rowPosition: 200, firstLoadedPosition: 200, hasMoreBefore: true, isLoading: false, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadBefore(rowPosition: 201, firstLoadedPosition: 200, hasMoreBefore: true, isLoading: false, hasError: false))
        // a window that starts at the top has nothing above it
        #expect(!PointsLeaderboardPaging.shouldLoadBefore(rowPosition: 1, firstLoadedPosition: 1, hasMoreBefore: true, isLoading: false, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadBefore(rowPosition: 200, firstLoadedPosition: 200, hasMoreBefore: false, isLoading: false, hasError: false))
        // the same in-flight and error guards as the forward trigger
        #expect(!PointsLeaderboardPaging.shouldLoadBefore(rowPosition: 200, firstLoadedPosition: 200, hasMoreBefore: true, isLoading: true, hasError: false))
        #expect(!PointsLeaderboardPaging.shouldLoadBefore(rowPosition: 200, firstLoadedPosition: 200, hasMoreBefore: true, isLoading: false, hasError: true))
    }

    // MARK: position indicator

    @Test func indicatorShowsOnlyForAPositionedPopulationTallerThanTheViewport() {
        #expect(PointsLeaderboardIndicator.isShown(total: 1000, firstLoadedPosition: 1, contentHeight: 3000, viewportHeight: 800))
        #expect(!PointsLeaderboardIndicator.isShown(total: 1000, firstLoadedPosition: 1, contentHeight: 600, viewportHeight: 800))
        #expect(!PointsLeaderboardIndicator.isShown(total: 1000, firstLoadedPosition: 1, contentHeight: 800, viewportHeight: 800))
        #expect(!PointsLeaderboardIndicator.isShown(total: 0, firstLoadedPosition: 1, contentHeight: 3000, viewportHeight: 800))
        #expect(!PointsLeaderboardIndicator.isShown(total: 1000, firstLoadedPosition: 1, contentHeight: 3000, viewportHeight: 0))
        // rows without positions (a server that does not send them yet): no thumb to place
        #expect(!PointsLeaderboardIndicator.isShown(total: 1000, firstLoadedPosition: 0, contentHeight: 3000, viewportHeight: 800))
    }

    @Test func thumbLengthIsTheWindowOverThePopulationWithAFloor() {
        // 50 of 1000 on a 1000pt track is 50pt: over the floor
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 50, total: 1000, trackLength: 1000) == 50)
        // 50 of 10000 would be 5pt: the 44pt floor holds
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 50, total: 10000, trackLength: 1000) == 44)
        // a window as large as the population fills the track, never more
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 1000, total: 1000, trackLength: 600) == 600)
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 2000, total: 1000, trackLength: 600) == 600)
        // a short track caps the floor; no track, no thumb
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 50, total: 10000, trackLength: 30) == 30)
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 50, total: 10000, trackLength: 0) == 0)
        // no population yet: the floor
        #expect(PointsLeaderboardIndicator.thumbLength(windowCount: 0, total: 0, trackLength: 1000) == 44)
    }

    @Test func thumbOffsetMapsRankOneToTheTopAndRankNToTheEnd() {
        // 1000pt track, 100pt thumb: 900pt of travel over ranks 1...1000
        #expect(PointsLeaderboardIndicator.thumbOffset(rank: 1, total: 1000, trackLength: 1000, thumbLength: 100) == 0)
        #expect(PointsLeaderboardIndicator.thumbOffset(rank: 1000, total: 1000, trackLength: 1000, thumbLength: 100) == 900)
        let mid = PointsLeaderboardIndicator.thumbOffset(rank: 500, total: 1000, trackLength: 1000, thumbLength: 100)
        #expect(abs(mid - 900 * 499 / 999) < 0.001)
        // out-of-range ranks clamp; a single rank or a thumb-sized track sits at the top
        #expect(PointsLeaderboardIndicator.thumbOffset(rank: 0, total: 1000, trackLength: 1000, thumbLength: 100) == 0)
        #expect(PointsLeaderboardIndicator.thumbOffset(rank: 5000, total: 1000, trackLength: 1000, thumbLength: 100) == 900)
        #expect(PointsLeaderboardIndicator.thumbOffset(rank: 1, total: 1, trackLength: 1000, thumbLength: 100) == 0)
        #expect(PointsLeaderboardIndicator.thumbOffset(rank: 7, total: 10, trackLength: 100, thumbLength: 100) == 0)
    }

    @Test func dragRankIsTheInverseOfTheThumbOffset() {
        for rank: Int64 in [1, 2, 137, 500, 999, 1000] {
            let offset = PointsLeaderboardIndicator.thumbOffset(rank: rank, total: 1000, trackLength: 1000, thumbLength: 100)
            #expect(PointsLeaderboardIndicator.rank(thumbOffset: offset, total: 1000, trackLength: 1000, thumbLength: 100) == rank)
        }
        // past either end of the travel clamps to the ends
        #expect(PointsLeaderboardIndicator.rank(thumbOffset: -50, total: 1000, trackLength: 1000, thumbLength: 100) == 1)
        #expect(PointsLeaderboardIndicator.rank(thumbOffset: 950, total: 1000, trackLength: 1000, thumbLength: 100) == 1000)
        // no travel or no population: rank 1
        #expect(PointsLeaderboardIndicator.rank(thumbOffset: 10, total: 1000, trackLength: 100, thumbLength: 100) == 1)
        #expect(PointsLeaderboardIndicator.rank(thumbOffset: 10, total: 0, trackLength: 1000, thumbLength: 100) == 1)
    }

    @Test func accessibilityStepsOnePercentOfThePopulationWithinItsBounds() {
        #expect(PointsLeaderboardIndicator.step(total: 1000) == 10)
        #expect(PointsLeaderboardIndicator.step(total: 50) == 1)
        #expect(PointsLeaderboardIndicator.steppedRank(1, total: 1000, direction: 1) == 11)
        #expect(PointsLeaderboardIndicator.steppedRank(995, total: 1000, direction: 1) == 1000)
        #expect(PointsLeaderboardIndicator.steppedRank(5, total: 1000, direction: -1) == 1)
        #expect(PointsLeaderboardIndicator.steppedRank(1, total: 0, direction: 1) == 1)
    }

    @Test func rankTextGroupsThousands() {
        let en = Locale(identifier: "en_US")
        #expect(PointsLeaderboardIndicator.rankText(1, locale: en) == "#1")
        #expect(PointsLeaderboardIndicator.rankText(1240, locale: en) == "#1,240")
        #expect(PointsLeaderboardIndicator.rankText(1_000_000, locale: en) == "#1,000,000")
    }

    // MARK: tab reset

    @Test func tabResetReloadsOnlyWhenTheWindowNoLongerStartsAtRankOne() {
        #expect(!PointsLeaderboardTabReset.reloadsFromTop(firstLoadedPosition: 1, rowCount: 50))
        #expect(PointsLeaderboardTabReset.reloadsFromTop(firstLoadedPosition: 200, rowCount: 50))
        // an empty list has nothing to reload; the controller's next page starts at the top
        #expect(!PointsLeaderboardTabReset.reloadsFromTop(firstLoadedPosition: 0, rowCount: 0))
    }
}
