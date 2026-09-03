//
//  PointsLeaderboardLogic.swift
//  URnetwork
//

import Foundation

/**
 * Pure rules behind the points leaderboard screen, kept free of SwiftUI and
 * of the sdk so they unit test without a device. The sdk view controller
 * owns the data; these only decide WHEN the screen asks it for more and HOW
 * the emoji editor reads a validation.
 */
enum PointsLeaderboardPaging {

    /// rows from the end at which the next page is requested
    static let loadMoreThreshold = 10

    /**
     * True when the list has scrolled close enough to its end that the next
     * page should be requested. `lastVisibleRowIndex` is the index into the
     * ROWS (header and footer excluded); -1 when no row is visible. The
     * controller itself refuses a second in-flight page and a page past the
     * end, so this only avoids asking in the first place.
     */
    static func shouldLoadMore(
        lastVisibleRowIndex: Int,
        rowCount: Int,
        isLoading: Bool,
        isEndReached: Bool,
        threshold: Int = loadMoreThreshold
    ) -> Bool {
        if rowCount <= 0 || isLoading || isEndReached || lastVisibleRowIndex < 0 {
            return false
        }
        return lastVisibleRowIndex >= rowCount - 1 - threshold
    }
}

/// Why the sdk rejected an emoji tag; mirrors the sdk's `EmojiTagReason*`.
enum EmojiTagError: Equatable {
    case empty
    case tooMany
    case notEmoji
}

enum EmojiTagEditor {

    // the sdk's reason strings (`SdkEmojiTagReasonEmpty` etc.), repeated here
    // as literals so this file never touches the sdk
    private static let reasonEmpty = "empty"
    private static let reasonTooMany = "too_many"

    /// The editor error for a rejected validation; nil when the tag is ok.
    static func errorFor(ok: Bool, reason: String?) -> EmojiTagError? {
        if ok {
            return nil
        }
        switch reason {
        case reasonEmpty:
            return .empty
        case reasonTooMany:
            return .tooMany
        default:
            // an unknown reason from a newer sdk still reads as "not emoji":
            // the only other way a tag is rejected
            return .notEmoji
        }
    }

    /**
     * Save is offered only for a valid tag that differs from what is stored.
     * The sdk's normalized form is what gets sent, so the comparison is on it.
     */
    static func canSave(ok: Bool, normalized: String, currentTag: String, isSaving: Bool) -> Bool {
        return ok && !isSaving && !normalized.isEmpty && normalized != currentTag
    }

    /**
     * An empty field is not an error while the user is still typing (or
     * clearing): the counter reads "0 / max" instead of "add an emoji".
     */
    static func showsError(text: String, error: EmojiTagError?) -> Bool {
        guard let error else {
            return false
        }
        return !(text.isEmpty && error == .empty)
    }

    /**
     * The tag without its last emoji: the editor's backspace. One emoji can
     * be several code points (skin tones, flags, ZWJ sequences); a Swift
     * `Character` is one grapheme cluster, so dropping one never cuts inside
     * a sequence.
     */
    static func dropLastEmoji(_ tag: String) -> String {
        if tag.isEmpty {
            return tag
        }
        return String(tag.dropLast())
    }
}
