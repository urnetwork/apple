//
//  ConnectSheetMomentum.swift
//  URnetwork
//

import Foundation

/**
 * Pure geometry for the connect drawer's release handling, shared by the
 * drag-end decision and the momentum carried into the drawer's content.
 *
 * Velocities are in points per second, positive downward as UIKit reports
 * them. The deceleration model is UIScrollView's: each millisecond the
 * velocity is multiplied by the deceleration rate, so a fling is memoryless
 * and its remaining travel is a closed form of its current velocity.
 */
enum ConnectSheetMomentum {

    /// The sheet's own velocity threshold: a release faster than this opens
    /// or closes the drawer regardless of how far it was dragged (the same
    /// 125 pt/s the Android sheet uses).
    static let velocityThreshold: CGFloat = 125

    /// Below the velocity threshold, the fraction of the drag range that
    /// must be covered to change state.
    static let positionalThreshold: CGFloat = 0.25

    /// Whether the drawer is expanded after a release. `translation` and
    /// `velocity` are negative when dragging up; `range` is the distance
    /// between the collapsed and expanded positions.
    static func isExpandedAfterRelease(
        isExpanded: Bool,
        translation: CGFloat,
        velocity: CGFloat,
        range: CGFloat
    ) -> Bool {
        if abs(velocity) >= velocityThreshold {
            return velocity < 0
        }
        let threshold = range * positionalThreshold
        if isExpanded {
            return !(translation > threshold)
        }
        return -translation > threshold
    }

    /// How far a fling of `speed` (points per second, non-negative) still
    /// travels under `decelerationRate`.
    static func projectedDistance(speed: CGFloat, decelerationRate: CGFloat) -> CGFloat {
        guard speed > 0, 0 < decelerationRate, decelerationRate < 1 else {
            return 0
        }
        return speed / 1000 * decelerationRate / (1 - decelerationRate)
    }

    /// The speed a fling of `speed` has left after covering `travelled`
    /// points; zero when it would have stopped within that distance.
    static func residualSpeed(speed: CGFloat, travelled: CGFloat, decelerationRate: CGFloat) -> CGFloat {
        guard speed > 0, 0 < decelerationRate, decelerationRate < 1 else {
            return 0
        }
        guard travelled > 0 else {
            return speed
        }
        return max(0, speed - travelled * 1000 * (1 - decelerationRate) / decelerationRate)
    }

}
