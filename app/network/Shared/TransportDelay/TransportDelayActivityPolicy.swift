//
//  TransportDelayActivityPolicy.swift
//  URnetwork
//
//  When the slow internet Live Activity starts, updates and ends
//  (apple/DELAY.md §5.5), as a pure value: whoever drives the activity feeds
//  it the device's readings, the toggle and the tunnel, and the clock, and
//  performs the action it returns. TransportDelayActivityPolicyTests pins it.
//
//  A notification surface must not flap, so it dwells: it appears only once
//  the level has been above 0 for 30 s of the last 60 s, then stays at
//  least 60 s, and a 3 s recovered state precedes its end. The in-app pill
//  follows the sdk's level directly and does not use this.
//
//  Compiled into the app and the packet tunnel extension.
//

import Foundation

struct TransportDelayActivityPolicy {
    typealias ContentState = TransportDelayAttributes.ContentState

    /// The window the dwell is measured over.
    static let dwellWindow: TimeInterval = 60
    /// Slow time within the window before the activity appears.
    static let dwellRequired: TimeInterval = 30
    /// Once up, the activity stays at least this long.
    static let minimumShown: TimeInterval = 60
    /// The recovered state shows this long, then the activity ends at once.
    static let recoveredHold: TimeInterval = 3
    /// The numbers refresh at most this often, and at least this often while
    /// the activity is up, which keeps it from going stale.
    static let refreshInterval: TimeInterval = 30
    /// Each start and update is stale this long after it, so a driver that
    /// stops (the extension killed) leaves the numbers muted.
    static let staleInterval: TimeInterval = 60
    /// The system ends an activity after eight hours.
    static let maximumDuration: TimeInterval = 8 * 60 * 60
    /// The soonest a dwell is checked again.
    static let minimumRecheck: TimeInterval = 1

    enum Phase: Equatable {
        /// No activity.
        case hidden
        /// Up since the date.
        case shown(since: Date)
        /// The recovered state, since the date.
        case recovered(since: Date)
    }

    enum Event: Equatable {
        /// The device's transport delay.
        case reading(TransportDelayReading)
        /// The toggle is on and the tunnel is connected.
        case enabled(Bool)
        /// Time passed (the driver's deadline, `nextDeadline`).
        case tick
        /// The activity went away without an end from here: the user
        /// dismissed it, or the system ended it (its eight hours).
        case gone(dismissedByUser: Bool)
    }

    enum Action: Equatable {
        case start(ContentState)
        case update(ContentState)
        /// With the dismissal policy immediate: the recovered state has
        /// already shown.
        case end
    }

    private(set) var phase: Phase = .hidden
    /// What the activity shows, nil while hidden.
    private(set) var content: ContentState? = nil
    private(set) var reading: TransportDelayReading = .normal
    private(set) var enabled = false
    /// The user dismissed the activity: it stays away until the slow spell is
    /// over, a whole window without a slow reading.
    private(set) var suppressed = false
    /// The last start or update.
    private(set) var updatedAt: Date? = nil

    /// The slow spans that ended within the window, oldest first, and the
    /// start of the one still open.
    private var slowSpans: [(start: Date, end: Date)] = []
    private var slowSince: Date? = nil

    /// Applies `event` at `now`, and returns what to do to the activity.
    mutating func step(_ event: Event, now: Date) -> Action? {
        switch event {
        case .reading(let next):
            apply(next, now: now)
        case .enabled(let next):
            if next && !enabled {
                // turned back on: a dismissal from before does not hold
                suppressed = false
            }
            enabled = next
        case .tick:
            break
        case .gone(let dismissedByUser):
            if phase != .hidden {
                hide()
                if dismissedByUser {
                    suppressed = true
                }
            }
        }
        return evaluate(now: now)
    }

    /// When to step again with `.tick` (or a fresh reading), nil when only a
    /// new event changes anything.
    func nextDeadline(now: Date) -> Date? {
        guard enabled else {
            return nil
        }
        switch phase {
        case .hidden:
            guard !suppressed, 0 < reading.level else {
                return nil
            }
            // the window gains at most the time that passes, so the dwell
            // cannot complete sooner than the slow time it lacks
            let missing = Self.dwellRequired - slowDuration(now: now)
            return now.addingTimeInterval(max(Self.minimumRecheck, missing))
        case .shown(let since):
            let refresh = (updatedAt ?? now).addingTimeInterval(Self.refreshInterval)
            if 0 < reading.level {
                return refresh
            }
            return min(refresh, since.addingTimeInterval(Self.minimumShown))
        case .recovered(let since):
            return since.addingTimeInterval(Self.recoveredHold)
        }
    }

    /// The stale date for a start or update made at `now`.
    static func staleDate(now: Date) -> Date {
        now.addingTimeInterval(staleInterval)
    }

    /// How long the activity has been up, nil while hidden.
    func shownDuration(now: Date) -> TimeInterval? {
        switch phase {
        case .shown(let since):
            return now.timeIntervalSince(since)
        case .hidden, .recovered:
            return nil
        }
    }

    /// The slow time within the window that ends at `now`.
    func slowDuration(now: Date) -> TimeInterval {
        let windowStart = now.addingTimeInterval(-Self.dwellWindow)
        var duration: TimeInterval = 0
        for span in slowSpans {
            let start = max(span.start, windowStart)
            if start < span.end {
                duration += span.end.timeIntervalSince(start)
            }
        }
        if let slowSince {
            let start = max(slowSince, windowStart)
            if start < now {
                duration += now.timeIntervalSince(start)
            }
        }
        return duration
    }

    private mutating func apply(_ next: TransportDelayReading, now: Date) {
        let wasSlow = 0 < reading.level
        let isSlow = 0 < next.level
        if !wasSlow && isSlow {
            if slowDuration(now: now) == 0 {
                // a new slow spell: a dismissal of the last one is over
                suppressed = false
            }
            slowSince = now
        } else if wasSlow && !isSlow {
            if let slowSince {
                slowSpans.append((start: slowSince, end: now))
            }
            slowSince = nil
        }
        reading = next
    }

    private mutating func evaluate(now: Date) -> Action? {
        prune(now: now)
        guard enabled else {
            if phase != .hidden {
                hide()
                return .end
            }
            return nil
        }
        switch phase {
        case .hidden:
            guard !suppressed, 0 < reading.level, Self.dwellRequired <= slowDuration(now: now) else {
                return nil
            }
            let next = ContentState(reading: reading, previousLevel: 0)
            phase = .shown(since: now)
            content = next
            updatedAt = now
            return .start(next)

        case .shown(let since):
            let shown = content ?? ContentState(reading: reading, previousLevel: 0)
            if 0 < reading.level {
                let changed = reading.level != shown.level || reading.fallback != shown.fallback
                guard changed || refreshDue(now: now) else {
                    return nil
                }
                // a change of level fades the squares that change; a refresh
                // moves only the numbers
                let next = ContentState(reading: reading, previousLevel: shown.level)
                content = next
                updatedAt = now
                return .update(next)
            }
            // back to normal: the activity waits out its minimum showing the
            // last slow content, then shows the recovered state
            if Self.minimumShown <= now.timeIntervalSince(since) {
                let next = shown.recoveredState
                phase = .recovered(since: now)
                content = next
                updatedAt = now
                return .update(next)
            }
            guard refreshDue(now: now) else {
                return nil
            }
            let next = shown.settled
            content = next
            updatedAt = now
            return .update(next)

        case .recovered(let since):
            if 0 < reading.level {
                // slow again before the end: the same activity carries on, and
                // stays its minimum again
                let next = ContentState(reading: reading, previousLevel: 0)
                phase = .shown(since: now)
                content = next
                updatedAt = now
                return .update(next)
            }
            guard Self.recoveredHold <= now.timeIntervalSince(since) else {
                return nil
            }
            hide()
            // the next activity dwells on slow time after this one
            slowSpans = []
            return .end
        }
    }

    private func refreshDue(now: Date) -> Bool {
        guard let updatedAt else {
            return true
        }
        return Self.refreshInterval <= now.timeIntervalSince(updatedAt)
    }

    private mutating func hide() {
        phase = .hidden
        content = nil
        updatedAt = nil
    }

    private mutating func prune(now: Date) {
        let windowStart = now.addingTimeInterval(-Self.dwellWindow)
        slowSpans.removeAll { $0.end <= windowStart }
    }
}
