//
//  ConnectSheetMomentum.swift
//  URnetwork
//

import Foundation

/**
 * Pure geometry for the connect drawer's release handling. Velocities are in
 * points per second, positive downward as UIKit reports them.
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

}
