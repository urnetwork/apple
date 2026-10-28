//
//  WidgetRefresh.swift
//  URnetwork
//
//  Asks WidgetKit to re-render the Control Center toggle and the Home Screen
//  widgets. Called from the app (on every tunnel status change) and from the
//  packet tunnel extension (when it starts, stops, or its snapshot changes
//  materially), because the widget process itself is never told when the
//  tunnel changes underneath it.
//
//  Reloads are hints, not guarantees: WidgetKit budgets them (roughly 40-70 a
//  day per widget instance) and reloads requested from a process other than
//  the foreground app are applied best-effort. Callers therefore rate-limit
//  themselves and the widgets show when their data was last written.
//
//  Every reload request also posts WidgetSnapshotChange, so the app's own
//  rendering of the widgets (Account > Widgets) follows the pinned widgets.
//
//  Compiled into the app, the packet tunnel extension and the widget
//  extension.
//

import Foundation
import WidgetKit

/// Every widget refresh cadence, in one place.
///
/// These numbers used to live in three files that each restated the same
/// budget and then picked a number in isolation: the timeline asked for a
/// reload every 20 minutes (72 a day) while the tunnel extension's routine
/// throttle asked every 15 (96 a day), against the roughly 40-70 a day
/// WidgetKit allows one widget instance. The two clocks do not add up --
/// every reload re-arms the timeline's `.after(...)`, so the faster one wins
/// and the slower one's budget is spent for nothing. Over-requesting is not
/// free: the system answers an over-subscribed budget with deferrals, which
/// is how a design asking twice per hour ended up refreshing less often than
/// either of its own numbers.
///
/// 25 minutes is ~58 requests a day, inside the band with headroom for the
/// event-driven reloads a real day contains (connect, disconnect, location
/// change). The extension's backstop is deliberately SLOWER than the
/// timeline policy so it fills a gap the policy left rather than racing it.
///
/// The freshness a user actually feels does not come from this clock. It
/// comes from the two paths that are not charged against the budget: a
/// reload caused by an in-widget intent (the refresh button), and a reload
/// requested while the app is in the foreground.
enum WidgetRefreshPolicy {

    /// Requested spacing between timeline reloads while the tunnel is up.
    static let refreshIntervalWhileUp: TimeInterval = 25 * 60

    /// While the tunnel is down there is no writer at all -- the snapshot
    /// writer lives in the packet tunnel process and its timers are cancelled
    /// on stop -- so no new snapshot can appear however often the widget
    /// asks. The only thing that can change is NEVPNStatus, and every
    /// transition already reloads from `VPNManager`.
    static let refreshIntervalWhileDown: TimeInterval = 60 * 60

    /// Entries re-render the same snapshot at later dates. Five minutes is
    /// the spacing WidgetKit expects; it is the one constant here that is not
    /// free to lower.
    static let entrySpacing: TimeInterval = 5 * 60

    /// WidgetKit archives every entry's rendered view up front, so entries
    /// are not free -- the globe archives a full render each. Six covers the
    /// tunnel-up policy exactly; the hour-long down policy is capped by it,
    /// which costs nothing because with the tunnel down there is no writer,
    /// nothing on screen is a function of the entry's date any more, and the
    /// freshness label advances itself.
    static let maxEntryCount = 6

    /// Enough entries that the last one lands on the policy date. Four
    /// entries five minutes apart covered only 15 minutes of a 20-minute
    /// policy, so the final stretch of every cycle rendered an entry whose
    /// date had already passed.
    static func entryCount(covering interval: TimeInterval) -> Int {
        min(maxEntryCount, max(1, Int((interval / entrySpacing).rounded(.down)) + 1))
    }

    /// The tunnel extension's routine reload floor. Slower than
    /// `refreshIntervalWhileUp` on purpose: a backstop, not a second clock.
    static let extensionBackstopInterval: TimeInterval = 30 * 60

    /// How long the overview waits on an urgent reload before it goes, so
    /// the two or three kinds one event reloads (a connect reloads all three)
    /// reload the overview once. Every one of them follows that event's
    /// single write, so the wait loses nothing.
    static let overviewUrgentDelay: TimeInterval = 1
}

enum WidgetRefresh {

    /// The Control Center / Lock Screen / Action button toggle (iOS 18,
    /// macOS 26). A no-op on earlier systems.
    ///
    /// iOS only at compile time: `ControlCenter` is a macOS 26 symbol, so it
    /// is simply absent from the macOS 15 SDK the CI toolchain (Xcode 16.4)
    /// builds against, and the `#available` check below cannot help — that is
    /// a runtime test, and the declaration has to exist to compile at all.
    /// The control ships on iOS only in practice, so on macOS this is a no-op
    /// rather than a missing method: `reloadAll()` and the app, tunnel
    /// extension and widget targets that call it all still build.
    static func reloadControl() {
        #if os(iOS)
        if #available(iOS 18.0, macOS 26.0, *) {
            ControlCenter.shared.reloadControls(ofKind: WidgetKinds.quickConnectControl)
        }
        #endif
    }

    static func reloadDashboard() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.dashboard)
        reloadOverview()
        WidgetSnapshotChange.post()
    }

    static func reloadProviderGlobe() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.providerGlobe)
        reloadOverview()
        WidgetSnapshotChange.post()
    }

    static func reloadContracts() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.contracts)
        reloadOverview()
        WidgetSnapshotChange.post()
    }

    /// Everything that shows tunnel state. Every kind directly, the overview
    /// too: the tunnel extension calls this as it stops, and its process can
    /// be reaped before a throttle's queue runs.
    static func reloadAll() {
        reloadControl()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.dashboard)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.providerGlobe)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.contracts)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.overview)
        WidgetSnapshotChange.post()
    }

    /// The overview shows what the other three show, so it reloads whenever
    /// one of them does -- but it is one widget with one budget. The tunnel
    /// extension's three throttles keep an interval each, and an urgent
    /// reload of one kind (the provide toggle reloads only the dashboard)
    /// restarts that kind's interval, so after a while they fire at three
    /// different moments: followed one for one, they would reload the
    /// overview up to three times an interval. Its own throttle keeps it to
    /// their cadence instead: a routine reload at most once an interval, and
    /// an urgent one (a connect, a location change, the slow internet pill,
    /// anything the app asks for) a moment later, once for all the kinds the
    /// same event reloads.
    private static func reloadOverview() {
        overviewReload.request(urgent: !WidgetReloadThrottle.firingRoutine)
    }

    private static let overviewReload = WidgetReloadThrottle(
        interval: WidgetRefreshPolicy.extensionBackstopInterval,
        urgentDelay: WidgetRefreshPolicy.overviewUrgentDelay
    ) {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.overview)
    }
}

/// Coalesces reload requests so a chatty source (a provider joining and
/// leaving every few minutes, a counter tick every second) cannot burn the
/// WidgetKit budget. `urgent` requests (connect, disconnect, location change)
/// go through at once, or `urgentDelay` later as one; routine ones wait for
/// the interval.
final class WidgetReloadThrottle {

    /// True while a throttle runs a routine reload (one it deferred, or let
    /// through because its interval had passed), false for an urgent one.
    /// WidgetRefresh reads it to give the overview's reload the urgency of
    /// the reload it follows.
    @TaskLocal static var firingRoutine = false

    private let interval: TimeInterval
    private let urgentDelay: TimeInterval
    private let queue: DispatchQueue
    private let reload: () -> Void
    private var lastReloadAt: Date?
    private var pending: DispatchWorkItem?
    private var pendingUrgent: DispatchWorkItem?

    init(
        interval: TimeInterval,
        urgentDelay: TimeInterval = 0,
        queue: DispatchQueue = DispatchQueue(label: "network.ur.widget-reload"),
        reload: @escaping () -> Void
    ) {
        self.interval = interval
        self.urgentDelay = urgentDelay
        self.queue = queue
        self.reload = reload
    }

    func request(urgent: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if urgent {
                guard 0 < self.urgentDelay else {
                    self.fire(at: now, routine: false)
                    return
                }
                // the urgent requests inside the delay go as one
                guard self.pendingUrgent == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pendingUrgent = nil
                    self.fire(at: Date(), routine: false)
                }
                self.pendingUrgent = work
                self.queue.asyncAfter(deadline: .now() + self.urgentDelay, execute: work)
                return
            }
            let elapsed = self.lastReloadAt.map { now.timeIntervalSince($0) } ?? .infinity
            if self.interval <= elapsed {
                self.fire(at: now, routine: true)
                return
            }
            guard self.pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.fire(at: Date(), routine: true)
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + (self.interval - elapsed), execute: work)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.pending?.cancel()
            self?.pending = nil
            self?.pendingUrgent?.cancel()
            self?.pendingUrgent = nil
        }
    }

    /// Any reload covers whatever is waiting: the waiting requests followed
    /// writes that are already on disk.
    private func fire(at date: Date, routine: Bool) {
        pending?.cancel()
        pending = nil
        pendingUrgent?.cancel()
        pendingUrgent = nil
        lastReloadAt = date
        Self.$firingRoutine.withValue(routine) {
            reload()
        }
    }
}
