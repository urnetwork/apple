//
//  TransportDelaySharedState.swift
//  URnetwork
//
//  What crosses between the app and the packet tunnel extension for the slow
//  internet Live Activity (apple/DELAY.md §5.6, §6):
//
//    - the extension publishes `Widgets/transport-delay.json`: its latest
//      reading and what its dwell policy has the Live Activity show, and
//      posts a Darwin notification. The app, in the foreground, starts or
//      updates the activity from it when the extension cannot.
//    - the app keeps the "Notify me when my internet is slow" toggle in the
//      App Group defaults, and posts a Darwin notification when it flips,
//      the one channel that reaches a running extension.
//
//  Compiled into the app and the packet tunnel extension. No SDK import.
//

import Foundation

/// The extension's slow internet state, as it last published it.
struct TransportDelaySnapshot: Codable, Equatable {
    var updatedAt: Date
    /// false once the tunnel stopped: nothing below is live
    var tunnelActive: Bool
    var reading: TransportDelayReading
    /// what the Live Activity shows, nil when the policy has it hidden
    var activity: TransportDelayAttributes.ContentState?
    /// when the activity's content goes stale
    var staleDate: Date?

    /// A snapshot older than this is from an extension that stopped writing
    /// (killed): it no longer says what to show. The extension rewrites it at
    /// least every refresh interval while an activity is up.
    static let freshInterval: TimeInterval = 90

    func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(updatedAt) < Self.freshInterval
    }
}

/// What the app in the foreground does to the Live Activity, from the
/// extension's last snapshot (TransportDelayActivityAppDriver).
enum TransportDelayAppActivityDecision: Equatable {
    /// Nothing shows: the toggle is off, no extension has published, its
    /// tunnel stopped, or its policy has the activity hidden.
    case end
    /// The extension has not written for a while (asleep, or killed): its
    /// snapshot no longer says what to show, so the activity is left as it
    /// is, marked stale by the system. Ending it would read to the extension
    /// as the user's dismissal.
    case leave
    /// The policy's content, until its stale date.
    case show(TransportDelayAttributes.ContentState, staleDate: Date)

    static func decide(
        snapshot: TransportDelaySnapshot?,
        enabled: Bool,
        now: Date
    ) -> TransportDelayAppActivityDecision {
        guard enabled, let snapshot, snapshot.tunnelActive else {
            return .end
        }
        guard snapshot.isFresh(now: now) else {
            return .leave
        }
        guard let content = snapshot.activity else {
            return .end
        }
        return .show(content, staleDate: snapshot.staleDate ?? TransportDelayActivityPolicy.staleDate(now: now))
    }
}

enum TransportDelaySnapshotStore {

    static let fileName = "transport-delay.json"
    static let darwinNotificationName = "network.ur.transport-delay.changed"

    static func load() -> TransportDelaySnapshot? {
        guard let url = WidgetSnapshotStore.directoryURL?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? WidgetSnapshotStore.decoder.decode(TransportDelaySnapshot.self, from: data)
    }

    /// Writes the snapshot whole and atomically, then tells the app.
    @discardableResult
    static func save(_ snapshot: TransportDelaySnapshot) -> Bool {
        guard let directory = WidgetSnapshotStore.directoryURL else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try WidgetSnapshotStore.encoder.encode(snapshot)
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            return false
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotificationName as CFString),
            nil, nil, true
        )
        return true
    }
}

/// "Notify me when my internet is slow": on by default (apple/DELAY.md §13
/// decision 3), in the App Group defaults so the extension reads it. The
/// name is the Live Activity's, which it gated first.
enum TransportDelayLiveActivitySetting {

    static let key = "network.ur.transport-delay.live-activity"
    static let darwinNotificationName = "network.ur.transport-delay.live-activity-setting"

    /// Nil when this build was not granted the group: the setting is then
    /// this process's alone, at its default.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: DiagnosticsLogContract.appGroupIdentifier)
    }

    static func isEnabled(in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) -> Bool {
        guard let value = defaults?.object(forKey: key) as? Bool else {
            return true
        }
        return value
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) {
        defaults?.set(enabled, forKey: key)
        post()
    }

    /// The Developer screen's episode (TransportDelaySimulation): when it
    /// started, in seconds since 1970. Absent when none was played.
    static let simulationKey = "network.ur.transport-delay.live-activity.simulation"

    static func simulationStartedAt(in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) -> Date? {
        guard let seconds = defaults?.object(forKey: simulationKey) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Plays the episode from `date`, or stops it (nil).
    static func setSimulationStartedAt(_ date: Date?, in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) {
        if let date {
            defaults?.set(date.timeIntervalSince1970, forKey: simulationKey)
        } else {
            defaults?.removeObject(forKey: simulationKey)
        }
        post()
    }

    private static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotificationName as CFString),
            nil, nil, true
        )
    }
}

/// A scripted slow episode, played from the Developer screen. While it plays,
/// the extension's dwell policy reads it in place of the device, so a phone
/// test needs neither a slow network nor servers that stamp the delay header.
/// The extension times it from the start in the App Group defaults, so it
/// plays on with the app in the background or closed.
///
/// Level 2 until the dwell starts the notice (30 s), then 4 and 3 while it
/// shows, so it updates twice. Normal from 75 s: the policy shows the
/// recovered state once its minimum has passed (90 s) and ends the notice
/// 3 s later.
enum TransportDelaySimulation {

    /// Each reading holds from its offset into the episode until the next.
    static let script: [(offset: TimeInterval, reading: TransportDelayReading)] = [
        (0, reading(level: 2, upDelayMillis: 420, downDelayMillis: 1_100, upBitsPerSecond: 380_000, downBitsPerSecond: 820_000)),
        (40, reading(level: 4, upDelayMillis: 1_300, downDelayMillis: 2_900, upBitsPerSecond: 150_000, downBitsPerSecond: 280_000)),
        (55, reading(level: 3, upDelayMillis: 800, downDelayMillis: 1_900, upBitsPerSecond: 210_000, downBitsPerSecond: 450_000)),
    ]
    /// From here the device's reading applies again.
    static let slowDuration: TimeInterval = 75
    /// The activity is gone by here: the dwell, its minimum and the recovered
    /// hold.
    static var duration: TimeInterval {
        TransportDelayActivityPolicy.dwellRequired
            + TransportDelayActivityPolicy.minimumShown
            + TransportDelayActivityPolicy.recoveredHold
    }

    /// The scripted reading `elapsed` seconds in, nil outside the slow part.
    static func reading(elapsed: TimeInterval) -> TransportDelayReading? {
        guard 0 <= elapsed, elapsed < slowDuration else {
            return nil
        }
        return script.last { $0.offset <= elapsed }?.reading
    }

    /// The first offset after `elapsed` where the reading changes, nil once
    /// the slow part is over.
    static func nextChange(after elapsed: TimeInterval) -> TimeInterval? {
        (script.map(\.offset) + [slowDuration]).first { elapsed < $0 }
    }

    /// Down is the worse direction, a level above up.
    private static func reading(
        level: Int,
        upDelayMillis: Int64,
        downDelayMillis: Int64,
        upBitsPerSecond: Int64,
        downBitsPerSecond: Int64
    ) -> TransportDelayReading {
        TransportDelayReading(
            upQuality: TransportDelayLevel.quality(level: level - 1),
            downQuality: TransportDelayLevel.quality(level: level),
            upBitsPerSecond: upBitsPerSecond,
            downBitsPerSecond: downBitsPerSecond,
            upDelayMillis: upDelayMillis,
            downDelayMillis: downDelayMillis
        )
    }
}

/// The live-activity log lines of the app and the extension, kept in the App
/// Group defaults for the Developer screen, so a phone test reads spike S1's
/// outcome without a Mac. Each process writes only its own key, so their
/// writes never race; the screen merges them. A clear is a time, for the same
/// reason. The lines are the ones os_log and the uploaded logs already get.
enum TransportDelayActivityLog {

    struct Entry: Codable, Equatable {
        var at: Date
        /// "ext" or "app"
        var source: String
        var line: String
    }

    static let extensionKey = "network.ur.transport-delay.live-activity.log.extension"
    static let appKey = "network.ur.transport-delay.live-activity.log.app"
    static let clearedKey = "network.ur.transport-delay.live-activity.log.cleared"
    /// The newest entries kept per process.
    static let limit = 40

    /// Appends to the calling process's own key.
    static func append(_ line: String, key: String, source: String, now: Date = Date(), in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) {
        guard let defaults else {
            return
        }
        var entries = load(key: key, in: defaults)
        entries.append(Entry(at: now, source: source, line: line))
        if limit < entries.count {
            entries.removeFirst(entries.count - limit)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    /// Both processes' entries since the last clear, oldest first.
    static func entries(in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) -> [Entry] {
        guard let defaults else {
            return []
        }
        let cleared = (defaults.object(forKey: clearedKey) as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        return (load(key: extensionKey, in: defaults) + load(key: appKey, in: defaults))
            .filter { cleared < $0.at }
            .sorted { $0.at < $1.at }
    }

    static func clear(now: Date = Date(), in defaults: UserDefaults? = TransportDelayLiveActivitySetting.defaults) {
        defaults?.set(now.timeIntervalSince1970, forKey: clearedKey)
    }

    private static func load(key: String, in defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }
}
