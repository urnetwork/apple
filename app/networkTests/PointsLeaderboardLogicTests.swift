import Testing
@testable import URnetwork

struct PointsLeaderboardLogicTests {

    @Test func loadMoreOnlyNearTheEndOfALoadedList() {
        // 50 rows, threshold 10: rows 39 and up ask for more
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 20, rowCount: 50, isLoading: false, isEndReached: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 38, rowCount: 50, isLoading: false, isEndReached: false))
        #expect(PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 39, rowCount: 50, isLoading: false, isEndReached: false))
        #expect(PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: false, isEndReached: false))
    }

    @Test func loadMoreNeverAsksWhileLoadingAtTheEndOrWithNothingVisible() {
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: true, isEndReached: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 49, rowCount: 50, isLoading: false, isEndReached: true))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: -1, rowCount: 50, isLoading: false, isEndReached: false))
        #expect(!PointsLeaderboardPaging.shouldLoadMore(lastVisibleRowIndex: 0, rowCount: 0, isLoading: false, isEndReached: false))
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
}
