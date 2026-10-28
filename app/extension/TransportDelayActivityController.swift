//
//  TransportDelayActivityController.swift
//  URnetworkVPN
//
//  Tells the user their internet is slow from the process that owns the
//  device (apple/DELAY.md §5.5, §5.6): the device's transport delay listener
//  feeds the dwell policy (TransportDelayActivityPolicy), and the policy's
//  start, update and end become a local notification posted from here. Each
//  step also publishes Widgets/transport-delay.json, which the app's Live
//  Activity path follows in the foreground (off until server pushes can keep
//  an activity up to date, the next step).
//
//  Spike S1 showed ActivityKit refuses this process: a start fails with
//  ActivityAuthorizationError.unsupportedTarget, and an activity the app
//  started is invisible here. A notification needs no app process, so it
//  shows with the app suspended or closed. Every post, removal and error is
//  written to the extension's diagnostics log (TunnelDiagnosticLog, tag
//  `live-activity`). While the Developer screen's scripted episode plays
//  (TransportDelaySimulation), it stands in for the device's readings, so a
//  phone test needs no slow network.
//
//  All work happens on one serial queue; the listener's callbacks hop onto
//  it. No SwiftUI and no ActivityKit here.
//

#if os(iOS)
import Foundation
import UserNotifications
import URnetworkExtensionSdk

final class TransportDelayActivityController {

    static let logTag = "live-activity"
    /// Lines per tunnel session (TunnelDiagnosticLineFilter).
    static let logLineLimit = 128

    private let device: SdkDeviceLocal
    private let diagnosticLog: TunnelDiagnosticLog
    private let queue = DispatchQueue(label: "network.ur.transport-delay-activity", qos: .utility)

    // owned by `queue`
    private var running = false
    private var tunnelConnected = false
    private var sub: SdkSubProtocol?
    private var policy = TransportDelayActivityPolicy()
    private var deadlineTimer: DispatchSourceTimer?
    // steps at each change of a scripted episode's reading (spike S1)
    private var simulationTimer: DispatchSourceTimer?
    private var lines = TunnelDiagnosticLineFilter(limit: TransportDelayActivityController.logLineLimit)
    // what the posted notification says, nil while none is posted
    private var posted: TransportDelayNotification.Kind?
    private var lastSnapshot: TransportDelaySnapshot?

    /// The controller the process-wide Darwin observer forwards to.
    private static weak var current: TransportDelayActivityController?
    private static var settingObserverRegistered = false

    init(device: SdkDeviceLocal, diagnosticLog: TunnelDiagnosticLog) {
        self.device = device
        self.diagnosticLog = diagnosticLog
    }

    // MARK: Lifecycle

    /// Subscribes to the device. The notice shows only once the tunnel is up
    /// (`tunnelStarted`).
    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            write(
                "session ios=\(ProcessInfo.processInfo.operatingSystemVersionString)"
                + " setting=\(TransportDelayLiveActivitySetting.isEnabled())"
            )
            UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
                let authorization = TransportDelayNotification.describe(settings.authorizationStatus)
                self?.queue.async {
                    self?.write("notifications authorization=\(authorization)")
                }
            }
            // a notice left by an earlier session (one that was killed) says
            // what nothing updates any more; this session's policy posts its
            // own once its dwell completes
            TransportDelayNotification.remove()

            // registration first: it does not replay the current value, so the
            // read after it misses nothing
            sub = device.add(TransportDelayActivityListener { [weak self] delay in
                let reading = TransportDelayReading(delay)
                self?.queue.async {
                    guard let self, self.running else { return }
                    // a scripted episode stands in for the device while it plays
                    self.step(.reading(self.simulatedReading() ?? reading))
                }
            })
            step(.reading(currentReading()))
            scheduleSimulation()

            Self.current = self
            Self.registerSettingObserver()
        }
    }

    /// The tunnel is up: the notice may show.
    func tunnelStarted() {
        queue.async { [self] in
            guard running else { return }
            tunnelConnected = true
            // the step takes up the toggle and the tunnel (`enabled`)
            step(.tick)
        }
    }

    /// The tunnel is going down: withdraws the notice at once and publishes
    /// that nothing shows.
    func tunnelStopped() {
        queue.sync { [self] in
            finish(reason: "tunnel stopped")
        }
    }

    /// Releases the listener and the timers and withdraws the notice (a sign
    /// out, a superseded start, the session closing).
    func close() {
        queue.sync { [self] in
            finish(reason: "closed")
        }
    }

    private func finish(reason: String) {
        guard running else { return }
        let now = Date()
        tunnelConnected = false
        write("finish reason=\(reason)")
        // the policy hides whatever it showed, with no recovered state
        _ = policy.step(.enabled(false), now: now)
        withdraw()
        publish(now: now, force: true)
        running = false
        if Self.current === self {
            Self.current = nil
        }
        sub?.close()
        sub = nil
        deadlineTimer?.cancel()
        deadlineTimer = nil
        simulationTimer?.cancel()
        simulationTimer = nil
    }

    /// The toggle is on and the tunnel is connected.
    private var enabled: Bool {
        tunnelConnected && TransportDelayLiveActivitySetting.isEnabled()
    }

    // MARK: Policy

    private func step(_ event: TransportDelayActivityPolicy.Event) {
        guard running else { return }
        let now = Date()
        var acted = false
        // the toggle is read on every step: its Darwin notification is not
        // delivered to a process that was suspended when it was posted
        if policy.enabled != enabled {
            acted = apply(.enabled(enabled), now: now) || acted
        }
        acted = apply(event, now: now) || acted
        publish(now: now, force: acted)
        schedule(now: now)
    }

    /// Steps the policy and performs what it returns; whether it acted.
    private func apply(_ event: TransportDelayActivityPolicy.Event, now: Date) -> Bool {
        let previousLevel = policy.content?.level
        guard let action = policy.step(event, now: now) else {
            return false
        }
        logStep(action, previousLevel: previousLevel)
        perform(action)
        return true
    }

    /// The notification follows the policy's content, but is posted again
    /// only when what it says changes (slow, fallback, recovered): each post
    /// alerts, so a change of level or a refresh of the numbers posts nothing.
    private func perform(_ action: TransportDelayActivityPolicy.Action) {
        switch action {
        case .start(let content), .update(let content):
            let kind = TransportDelayNotification.Kind(content)
            guard kind != posted else {
                return
            }
            posted = kind
            post(kind)
        case .end:
            withdraw()
        }
    }

    private func post(_ kind: TransportDelayNotification.Kind) {
        let request = UNNotificationRequest(
            identifier: TransportDelayNotification.identifier,
            content: TransportDelayNotification.content(kind),
            trigger: nil
        )
        // the same identifier replaces the notice in place
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if let error = error as NSError? {
                    // UNError.notificationsNotAllowed (1): the app's
                    // "Receive connection notifications" is off
                    self.write("notification failed \(error.domain) code=\(error.code)")
                } else {
                    self.write("notification posted \(kind.logName)")
                }
            }
        }
    }

    private func withdraw() {
        guard posted != nil else {
            return
        }
        posted = nil
        TransportDelayNotification.remove()
        write("notification removed")
    }

    /// The policy's next deadline: a fresh reading then, which also moves the
    /// numbers the listener does not report (it fires on level changes only).
    private func schedule(now: Date) {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let deadline = policy.nextDeadline(now: now) else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSince(now)), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.step(.reading(self.currentReading()))
        }
        timer.resume()
        deadlineTimer = timer
    }

    // MARK: Simulation

    /// The scripted episode's reading while one plays, else nil.
    private func simulatedReading(now: Date = Date()) -> TransportDelayReading? {
        guard let startedAt = TransportDelayLiveActivitySetting.simulationStartedAt() else {
            return nil
        }
        return TransportDelaySimulation.reading(elapsed: now.timeIntervalSince(startedAt))
    }

    /// The reading the policy steps on: the episode's while one plays, else
    /// the device's.
    private func currentReading() -> TransportDelayReading {
        simulatedReading() ?? TransportDelayReading(device.getTransportDelay())
    }

    /// While an episode plays, steps at its next change, the end of its slow
    /// part included. The device's listener does not fire for it.
    private func scheduleSimulation() {
        simulationTimer?.cancel()
        simulationTimer = nil
        guard let startedAt = TransportDelayLiveActivitySetting.simulationStartedAt() else {
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard let next = TransportDelaySimulation.nextChange(after: elapsed) else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // a little past the change, so the read there lands on the new
        // reading; on the wall clock, which the script is timed by, so a
        // delayed start is not pushed back by the time the phone slept
        timer.schedule(wallDeadline: .now() + max(0, next - elapsed) + 0.05, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let reading = self.currentReading()
            self.write("simulation level=\(reading.level)")
            self.step(.reading(reading))
            self.scheduleSimulation()
        }
        timer.resume()
        simulationTimer = timer
    }

    /// Publishes the reading and the policy's content, when either changed
    /// or an action was taken (which keeps the snapshot fresh for the app
    /// while the notice shows).
    private func publish(now: Date, force: Bool) {
        let snapshot = TransportDelaySnapshot(
            updatedAt: now,
            tunnelActive: running && tunnelConnected,
            reading: policy.reading,
            activity: policy.content,
            staleDate: policy.content == nil ? nil : TransportDelayActivityPolicy.staleDate(now: now)
        )
        var comparable = snapshot
        comparable.updatedAt = lastSnapshot?.updatedAt ?? now
        comparable.staleDate = lastSnapshot?.staleDate
        guard force || comparable != lastSnapshot else {
            return
        }
        if TransportDelaySnapshotStore.save(snapshot) {
            lastSnapshot = snapshot
        } else {
            write("failed to write the snapshot")
        }
    }

    // MARK: Setting

    /// One Darwin observer per process; the callback is a C function
    /// pointer, so it reaches the live controller through `current`.
    private static func registerSettingObserver() {
        guard !settingObserverRegistered else { return }
        settingObserverRegistered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                TransportDelayActivityController.current?.settingChanged()
            },
            TransportDelayLiveActivitySetting.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func settingChanged() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let simulation = TransportDelayLiveActivitySetting.simulationStartedAt().map {
                "at \(Int(Date().timeIntervalSince($0).rounded()))s"
            } ?? "off"
            self.write(
                "setting=\(TransportDelayLiveActivitySetting.isEnabled())"
                + " simulation=\(simulation)"
            )
            // an episode started or stopped changes the reading, not just the toggle
            self.scheduleSimulation()
            self.step(.reading(self.currentReading()))
        }
    }

    // MARK: Log

    private func logStep(_ action: TransportDelayActivityPolicy.Action, previousLevel: Int?) {
        switch action {
        case .start(let content):
            write("policy start level=\(content.level) fallback=\(content.fallback)")
        case .update(let content):
            if content.recovered {
                write("policy recovered")
            } else if content.level != previousLevel {
                write("policy update level=\(previousLevel ?? 0)->\(content.level) fallback=\(content.fallback)")
            }
            // a refresh of the numbers writes nothing
        case .end:
            write("policy end")
        }
    }

    /// Writes one line to os_log and the uploaded logs, bounded per session.
    /// On `queue` only.
    private func write(_ line: String) {
        guard let admitted = lines.admit(line) else { return }
        diagnosticLog.write(tag: Self.logTag, line: admitted)
        // the Developer screen's copy, for a phone test without a Mac
        TransportDelayActivityLog.append(admitted, key: TransportDelayActivityLog.extensionKey, source: "ext")
    }
}

/// The slow internet notification (apple/DELAY.md §5.5). One identifier, so
/// each post replaces the last in place. The copy is the app's: the
/// notification belongs to the app, which localizes its keys when it shows.
enum TransportDelayNotification {

    static let identifier = "network.ur.slow-internet"

    /// What the notification says.
    enum Kind: Equatable {
        case slow(fallback: Bool)
        case recovered

        init(_ content: TransportDelayAttributes.ContentState) {
            self = content.recovered ? .recovered : .slow(fallback: content.fallback)
        }

        var logName: String {
            switch self {
            case .slow(let fallback):
                return fallback ? "slow fallback" : "slow"
            case .recovered:
                return "recovered"
            }
        }
    }

    static func content(_ kind: Kind) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        switch kind {
        case .slow(let fallback):
            content.title = localized(fallback ? "Using a slower fallback connection" : "Slow internet")
            content.body = localized("URnetwork is still connected")
        case .recovered:
            content.title = localized("Internet back to normal")
            content.body = localized("Delays cleared")
        }
        // a banner without a sound: news about the connection, not an alarm
        content.sound = nil
        content.interruptionLevel = .active
        content.threadIdentifier = identifier
        return content
    }

    static func remove() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not-determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    /// Resolved from the app's strings when the notification shows.
    private static func localized(_ key: String) -> String {
        NSString.localizedUserNotificationString(forKey: key, arguments: nil)
    }
}

extension TransportDelayReading {

    /// A copy of the sdk's reading; nil reads as normal.
    init(_ delay: SdkTransportDelay?) {
        guard let delay else {
            self = .normal
            return
        }
        self.init(
            upQuality: delay.upQuality,
            downQuality: delay.downQuality,
            upBitsPerSecond: delay.upBitsPerSecond,
            downBitsPerSecond: delay.downBitsPerSecond,
            upDelayMillis: delay.upQueueDelayMillis,
            downDelayMillis: delay.downQueueDelayMillis,
            fallback: delay.fallback
        )
    }
}

private final class TransportDelayActivityListener: NSObject, SdkTransportDelayChangeListenerProtocol {
    private let c: (SdkTransportDelay?) -> Void
    init(c: @escaping (SdkTransportDelay?) -> Void) { self.c = c }
    func transportDelayChanged(_ delay: SdkTransportDelay?) { c(delay) }
}
#endif
