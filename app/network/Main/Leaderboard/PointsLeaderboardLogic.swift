//
//  PointsLeaderboardLogic.swift
//  URnetwork
//

import CoreGraphics
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
     *
     * A failed page parks the list: `hasError` holds the trigger off until
     * the footer's Retry re-requests it. Keyed on `isLoading` alone, a failed
     * page flipped loading back to false, the trigger re-evaluated as true,
     * and the same request was fired again without pause (a request storm
     * against an unreachable server on the other platforms).
     */
    static func shouldLoadMore(
        lastVisibleRowIndex: Int,
        rowCount: Int,
        isLoading: Bool,
        isEndReached: Bool,
        hasError: Bool,
        threshold: Int = loadMoreThreshold
    ) -> Bool {
        if rowCount <= 0 || isLoading || isEndReached || hasError || lastVisibleRowIndex < 0 {
            return false
        }
        return lastVisibleRowIndex >= rowCount - 1 - threshold
    }

    /**
     * True when the row that just came into view is the first loaded one and
     * the controller holds ranks above it (after a seek or a previous backward
     * page), so the page before the window should be requested. The same
     * in-flight and error guards as the forward trigger apply.
     */
    static func shouldLoadBefore(
        rowPosition: Int64,
        firstLoadedPosition: Int64,
        hasMoreBefore: Bool,
        isLoading: Bool,
        hasError: Bool
    ) -> Bool {
        if !hasMoreBefore || isLoading || hasError || firstLoadedPosition <= 1 {
            return false
        }
        return rowPosition == firstLoadedPosition
    }
}

/**
 * The draggable position indicator on the points list (mmm/DESIGNSTYLE.md,
 * "Long ranked lists: tab reset and a draggable position indicator"): its
 * track spans ranks 1 to N where N is the controller's total ranked count,
 * not the rows loaded so far. The thumb sits at the rank of the first visible
 * row and is as long as the loaded window over N, with a floor so it stays a
 * hand-sized target. All of it is geometry over the controller's counts; the
 * seek itself is the controller's.
 */
enum PointsLeaderboardIndicator {

    /// the smallest thumb, in points: a hand-sized drag target
    static let minThumbLength: CGFloat = 44
    /// the thumb's hit target width, in points
    static let thumbWidth: CGFloat = 24

    /**
     * Shown only for a ranked population whose rows carry positions and a
     * list taller than its viewport: a short list scrolls fine on its own and
     * would draw a thumb the size of the track, and without positions (a
     * server that does not send them yet) there is no place to put the thumb.
     */
    static func isShown(
        total: Int64,
        firstLoadedPosition: Int64,
        contentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        return total > 0 && firstLoadedPosition > 0 && viewportHeight > 0 && contentHeight > viewportHeight
    }

    /**
     * The thumb's length for a loaded window of `windowCount` rows out of
     * `total`: proportional to the window, never below `minLength`, never
     * longer than the track.
     */
    static func thumbLength(
        windowCount: Int64,
        total: Int64,
        trackLength: CGFloat,
        minLength: CGFloat = minThumbLength
    ) -> CGFloat {
        if trackLength <= 0 {
            return 0
        }
        if total <= 0 {
            return min(trackLength, minLength)
        }
        let window = max(0, min(windowCount, total))
        let proportional = trackLength * CGFloat(window) / CGFloat(total)
        return min(trackLength, max(minLength, proportional))
    }

    /**
     * Where the thumb's top sits for `rank`: rank 1 at the top of the track,
     * rank N with the thumb's end at the track's end.
     */
    static func thumbOffset(rank: Int64, total: Int64, trackLength: CGFloat, thumbLength: CGFloat) -> CGFloat {
        let travel = max(0, trackLength - thumbLength)
        if total <= 1 || travel <= 0 {
            return 0
        }
        let clamped = min(max(rank, 1), total)
        return travel * CGFloat(clamped - 1) / CGFloat(total - 1)
    }

    /**
     * The inverse: the rank under a thumb whose top is at `thumbOffset`, for
     * the drag. Offsets past either end clamp to rank 1 or N.
     */
    static func rank(thumbOffset: CGFloat, total: Int64, trackLength: CGFloat, thumbLength: CGFloat) -> Int64 {
        if total <= 1 {
            return max(total, 1)
        }
        let travel = trackLength - thumbLength
        if travel <= 0 {
            return 1
        }
        let fraction = min(1, max(0, thumbOffset / travel))
        return 1 + Int64((fraction * CGFloat(total - 1)).rounded())
    }

    /// the accessibility increment: one percent of the population, at least one rank
    static func step(total: Int64) -> Int64 {
        return max(1, total / 100)
    }

    /// `rank` moved one accessibility step up (+1) or down (-1), kept in 1...N
    static func steppedRank(_ rank: Int64, total: Int64, direction: Int) -> Int64 {
        if total <= 0 {
            return 1
        }
        let moved = rank + step(total: total) * Int64(direction.signum())
        return min(max(moved, 1), total)
    }

    /// "#1,240": the rank with the locale's grouping separators
    static func rankText(_ rank: Int64, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        let number = formatter.string(from: NSNumber(value: rank)) ?? String(rank)
        return "#" + number
    }
}

/**
 * Tapping a tab, including the one already selected, scrolls its list to the
 * top. On the points list that is only the top of the loaded window; when the
 * window no longer starts at rank 1 (after a seek or backward paging) the
 * controller reloads from the top too, so the top of the screen is rank 1.
 */
enum PointsLeaderboardTabReset {

    static func reloadsFromTop(firstLoadedPosition: Int64, rowCount: Int) -> Bool {
        return rowCount > 0 && firstLoadedPosition > 1
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
