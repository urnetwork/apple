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
//  Compiled into the app, the packet tunnel extension and the widget
//  extension.
//

import Foundation
import WidgetKit

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
    }

    static func reloadProviderGlobe() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.providerGlobe)
    }

    static func reloadContracts() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.contracts)
    }

    /// Everything that shows tunnel state.
    static func reloadAll() {
        reloadControl()
        reloadDashboard()
        reloadProviderGlobe()
        reloadContracts()
    }
}

/// Coalesces reload requests so a chatty source (a provider joining and
/// leaving every few minutes, a counter tick every second) cannot burn the
/// WidgetKit budget. `urgent` requests (connect, disconnect, location change)
/// go through at once; routine ones wait for the interval.
final class WidgetReloadThrottle {

    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let reload: () -> Void
    private var lastReloadAt: Date?
    private var pending: DispatchWorkItem?

    init(
        interval: TimeInterval,
        queue: DispatchQueue = DispatchQueue(label: "network.ur.widget-reload"),
        reload: @escaping () -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.reload = reload
    }

    func request(urgent: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if urgent {
                self.fire(at: now)
                return
            }
            let elapsed = self.lastReloadAt.map { now.timeIntervalSince($0) } ?? .infinity
            if self.interval <= elapsed {
                self.fire(at: now)
                return
            }
            guard self.pending == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.fire(at: Date())
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + (self.interval - elapsed), execute: work)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.pending?.cancel()
            self?.pending = nil
        }
    }

    private func fire(at date: Date) {
        pending?.cancel()
        pending = nil
        lastReloadAt = date
        reload()
    }
}
