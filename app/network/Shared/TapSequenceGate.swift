//
//  TapSequenceGate.swift
//  URnetwork
//
//  Counts a run of taps: `count` taps, each within `window` of the previous,
//  complete the sequence. A longer gap starts the count over, and a
//  completed sequence starts over too, so the next run needs the full count
//  again. Pure value: the caller passes the time of each tap.
//

import Foundation

struct TapSequenceGate {

    let count: Int
    let window: TimeInterval

    private(set) var taps: Int = 0
    private var lastTap: Date? = nil

    init(count: Int, window: TimeInterval) {
        self.count = count
        self.window = window
    }

    /// Registers a tap at `now`; true when this tap completes the sequence.
    mutating func register(at now: Date = Date()) -> Bool {
        if let lastTap, now.timeIntervalSince(lastTap) <= window {
            taps += 1
        } else {
            // the first tap, or a tap after too long a gap: a new run
            taps = 1
        }
        lastTap = now
        if taps >= count {
            taps = 0
            lastTap = nil
            return true
        }
        return false
    }

    mutating func reset() {
        taps = 0
        lastTap = nil
    }
}
