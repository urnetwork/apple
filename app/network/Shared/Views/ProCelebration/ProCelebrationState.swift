//
//  ProCelebrationState.swift
//  URnetwork
//
//  The launcher of the Pro celebration flight: a sequence number every host
//  of the flight observes. Each launch bumps it, so a replay is a new burst;
//  zero is idle. The purchase flow and the account's Pro label launch it.
//

import Foundation
import Combine

/// How long one celebration runs, all told: the confetti streams for the first 15 s,
/// and the pixelation of the screen under it fades in over the first 5 s, holds while
/// the confetti flies, and fades out over the 5 s after it, so the screen is sharp
/// again at 20 s. Shared by every reader so the sprites and the pixelation agree.
enum ProCelebrationTiming {
    static let totalSeconds: Double = 20
    static let confettiSeconds: Double = 15
    static let pixelateInSeconds: Double = 5
    static let pixelateOutStartSeconds: Double = 15
    static let pixelateOutSeconds: Double = 5
    /// The coarsest pixel cell of the mosaic, in points.
    static let pixelateMaxCell: Double = 24

    /// The pixel cell size at `seconds` into the flight: ease in, hold, ease out; 0 = sharp.
    static func pixelCell(at seconds: Double) -> Double {
        guard seconds > 0, seconds < totalSeconds else {
            return 0
        }
        let ramp: Double
        if seconds < pixelateInSeconds {
            ramp = easeInOut(seconds / pixelateInSeconds)
        } else if seconds > pixelateOutStartSeconds {
            let remaining = (pixelateOutStartSeconds + pixelateOutSeconds - seconds) / pixelateOutSeconds
            ramp = easeInOut(min(max(remaining, 0), 1))
        } else {
            ramp = 1
        }
        return ramp * pixelateMaxCell
    }

    /// A fast-out slow-in curve (the same shape the Android flight uses).
    static func easeInOut(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

/// Observed by every `proCelebrationLayer` host; `sequence` 0 means no flight.
final class ProCelebrationState: ObservableObject {

    @Published private(set) var sequence: Int = 0

    /// Starts a new flight (or restarts the current one with a fresh burst).
    func launch() {
        sequence += 1
    }

    /// Called by a host when the flight it played has ended.
    func finish(_ flown: Int) {
        if sequence == flown {
            sequence = 0
        }
    }
}
