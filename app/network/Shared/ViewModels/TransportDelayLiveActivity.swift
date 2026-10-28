//
//  TransportDelayLiveActivity.swift
//  URnetwork
//
//  The app's half of the slow internet notice (apple/DELAY.md §5.5, §6): the
//  "Notify me when my internet is slow" toggle, which gates the tunnel
//  extension's notification, the Developer screen's scripted episode, and on
//  iOS the Live Activity's foreground path, off until server pushes can keep
//  the activity up to date.
//

import Foundation
import UserNotifications
import URnetworkSdk

/// "Notify me when my internet is slow", for Settings.
/// The value lives in the App Group defaults (TransportDelayLiveActivitySetting),
/// where the tunnel extension reads it; this mirrors it for the views.
@MainActor
final class TransportDelayLiveActivityPreference: ObservableObject {

    static let shared = TransportDelayLiveActivityPreference()

    @Published private(set) var enabled: Bool
    /// When the Developer screen's episode started (TransportDelaySimulation).
    @Published private(set) var simulationStartedAt: Date?

    private init() {
        enabled = TransportDelayLiveActivitySetting.isEnabled()
        simulationStartedAt = TransportDelayLiveActivitySetting.simulationStartedAt()
    }

    /// Turned off, the extension withdraws its notification at once (the
    /// Darwin notification); turned on, it posts again if the connection is
    /// still slow. Turning it on asks for notification permission when the
    /// user has not been asked yet: without it the extension cannot post.
    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else {
            return
        }
        self.enabled = enabled
        TransportDelayLiveActivitySetting.setEnabled(enabled)
        #if os(iOS)
        TransportDelayActivityAppDriver.shared.settingChanged()
        #endif
        if enabled {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else {
                    return
                }
                center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
            }
        }
    }

    /// Plays the spike episode in the tunnel extension, `delay` seconds from
    /// now. A delay lets the app be suspended, closed or not yet launched
    /// (after a restart) when the extension's start comes.
    func playSimulation(after delay: TimeInterval = 0) {
        let start = Date().addingTimeInterval(delay)
        simulationStartedAt = start
        TransportDelayLiveActivitySetting.setSimulationStartedAt(start)
    }

    /// The seconds until a delayed episode starts, nil once it has or when
    /// none plays.
    func simulationStartsIn(now: Date) -> TimeInterval? {
        guard let simulationStartedAt, now < simulationStartedAt else {
            return nil
        }
        return simulationStartedAt.timeIntervalSince(now)
    }

    /// Stops the episode: the extension reads the device again, so an
    /// activity up recovers and ends as it would on a normal reading.
    func stopSimulation() {
        simulationStartedAt = nil
        TransportDelayLiveActivitySetting.setSimulationStartedAt(nil)
    }

    /// The seconds until the episode's activity is gone, nil when none plays.
    func simulationRemaining(now: Date) -> TimeInterval? {
        guard let simulationStartedAt else {
            return nil
        }
        let remaining = TransportDelaySimulation.duration - now.timeIntervalSince(simulationStartedAt)
        return 0 < remaining ? remaining : nil
    }
}

#if os(iOS)
/**
 * The app process's ActivityKit path, off for now (apple/DELAY.md §5.5).
 * ActivityKit lets only the app start, update and end the activity, and only
 * while it runs (spike S1): the tunnel extension is refused, so an activity
 * the app started would freeze once the app is suspended. It turns back on
 * when server pushes can update and end the activity, the next step. While
 * off, a reconcile only ends an activity an earlier build left up.
 *
 * When on, while the app is in the foreground it follows the extension's
 * published decision (TransportDelaySnapshot): it starts the activity the
 * policy wants up when none is, re-attaches to one already up through
 * Activity.activities and updates it, and ends it when the policy has it
 * hidden, the snapshot went stale (an extension that stopped writing), the
 * toggle went off, or the user signed out.
 */
@MainActor
final class TransportDelayActivityAppDriver {

    static let shared = TransportDelayActivityAppDriver()

    /// Off until server pushes can keep the activity up to date.
    static let showsActivity = false

    private static let logTag = "live-activity"

    private var foreground = false
    private var observerRegistered = false
    // a TransportDelayActivityPresenter on iOS 16.2+ (stored untyped: a
    // stored property cannot be marked available)
    private var presenter: AnyObject?

    private init() {}

    /// The app came to the foreground (`true`) or left it.
    func setForeground(_ foreground: Bool) {
        self.foreground = foreground
        guard foreground else {
            return
        }
        registerObserver()
        reconcile()
    }

    func settingChanged() {
        reconcile()
    }

    /// A sign out ends the activity at once, ahead of the extension's own end.
    func signedOut() {
        guard #available(iOS 16.2, *) else {
            return
        }
        livePresenter().endAll()
    }

    fileprivate func snapshotChanged() {
        guard foreground else {
            return
        }
        reconcile()
    }

    private func reconcile() {
        guard #available(iOS 16.2, *) else {
            return
        }
        let presenter = livePresenter()
        guard Self.showsActivity else {
            presenter.endAll()
            return
        }
        let decision = TransportDelayAppActivityDecision.decide(
            snapshot: TransportDelaySnapshotStore.load(),
            enabled: TransportDelayLiveActivitySetting.isEnabled(),
            now: Date()
        )
        switch decision {
        case .end:
            presenter.endAll()
        case .leave:
            break
        case .show(let content, let staleDate):
            presenter.show(content, staleDate: staleDate, allowStart: foreground)
        }
    }

    @available(iOS 16.2, *)
    private func livePresenter() -> TransportDelayActivityPresenter {
        if let presenter = presenter as? TransportDelayActivityPresenter {
            return presenter
        }
        let tag = Self.logTag
        let presenter = TransportDelayActivityPresenter { line in
            print("[TransportDelayActivity] \(line)")
            // the app half of a diagnostics upload
            SdkLogAppInfo(tag, "app " + line)
            // and of the Developer screen's log
            TransportDelayActivityLog.append(line, key: TransportDelayActivityLog.appKey, source: "app")
        }
        self.presenter = presenter
        return presenter
    }

    /// The extension posts each snapshot it writes. One observer per process;
    /// the callback is a C function pointer and reaches the driver through
    /// `shared`.
    private func registerObserver() {
        guard !observerRegistered else {
            return
        }
        observerRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    TransportDelayActivityAppDriver.shared.snapshotChanged()
                }
            },
            TransportDelaySnapshotStore.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}
#endif
