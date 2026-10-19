//
//  LocationsRefreshTicker.swift
//  URnetwork
//

import Foundation

/// A repeating timer that can be cancelled.
protocol RefreshTimer: AnyObject {
    func cancel()
}

/// Schedules `action` every `interval` seconds on the main actor until the
/// returned timer is cancelled. Injected so tests can drive time by hand.
typealias RefreshTimerScheduler = @MainActor (
    _ interval: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> RefreshTimer

private final class FoundationRefreshTimer: RefreshTimer {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}

@MainActor
func scheduleFoundationRefreshTimer(
    _ interval: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> RefreshTimer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
        MainActor.assumeIsolated {
            action()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    return FoundationRefreshTimer(timer: timer)
}

// one GET /network/provider-locations a minute while the home screen shows
let locationsRefreshInterval: TimeInterval = 60

/// Fetches the locations list again every interval while the home screen is
/// visible, so the provider counts it shows follow the network.
///
/// Ticks only between setVisible(true) and setVisible(false); the first fetch
/// is one interval after becoming visible, since showing the screen already
/// has the last fetch. A tick is skipped while `isFetching` (a fetch is in
/// flight), so fetches never overlap.
@MainActor
final class LocationsRefreshTicker {
    private let interval: TimeInterval
    private let schedule: RefreshTimerScheduler
    private let isFetching: @MainActor () -> Bool
    private let refresh: @MainActor () -> Void
    private var timer: RefreshTimer?

    init(
        interval: TimeInterval = locationsRefreshInterval,
        schedule: @escaping RefreshTimerScheduler = scheduleFoundationRefreshTimer,
        isFetching: @escaping @MainActor () -> Bool,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.interval = interval
        self.schedule = schedule
        self.isFetching = isFetching
        self.refresh = refresh
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard timer == nil else { return }
            timer = schedule(interval) { [weak self] in
                guard let self, !self.isFetching() else { return }
                self.refresh()
            }
        } else {
            timer?.cancel()
            timer = nil
        }
    }
}
