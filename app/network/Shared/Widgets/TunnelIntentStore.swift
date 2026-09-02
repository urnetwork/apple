//
//  TunnelIntentStore.swift
//  URnetwork
//
//  The user's most recent connect/disconnect decision, shared across every
//  process that can make one: the app, the widget extension (Control Center
//  toggle and the Home Screen widget's toggle) and the packet tunnel extension.
//
//  Why this exists: the app derives "should the tunnel run" from the SDK's
//  local state (a saved connect location means connect), and the app and the
//  extension each keep a private copy of that state. A toggle made from
//  Control Center while the app is closed therefore has nothing to update on
//  the app's side, and the app's next foreground reconcile would undo it. The
//  intent recorded here is the tie-breaker: whichever decision is newest wins,
//  and the app folds it into its own state before reconciling.
//
//  Compiled into the app, the packet tunnel extension and the widget extension
//  (listed explicitly in their sources phases). No SDK import, on purpose.
//

import Foundation

struct TunnelIntent: Codable, Equatable {

    /// true = the user asked for the tunnel to be up.
    var connect: Bool

    /// When the decision was made.
    var changedAt: Date

    /// Who recorded it, for diagnostics: see the `TunnelIntentStore.source*`
    /// constants.
    var source: String
}

enum TunnelIntentStore {

    static let key = "network.ur.tunnel-intent"

    static let sourceApp = "app"
    static let sourceControl = "control"
    static let sourceWidget = "widget"
    /// A stop the user made outside URnetwork: Settings > VPN or the system's
    /// own VPN control. Recorded by the packet tunnel extension.
    static let sourceSystem = "system"

    /// Shared defaults live in the App Group. Nil when this build was not
    /// granted the group (a provisioning profile without it), in which case
    /// intents simply are not shared and each process keeps its own behavior.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: DiagnosticsLogContract.appGroupIdentifier)
    }

    static func load(from defaults: UserDefaults? = TunnelIntentStore.defaults) -> TunnelIntent? {
        guard let data = defaults?.data(forKey: key) else {
            return nil
        }
        return try? decoder.decode(TunnelIntent.self, from: data)
    }

    @discardableResult
    static func record(
        connect: Bool,
        source: String,
        at date: Date = Date(),
        in defaults: UserDefaults? = TunnelIntentStore.defaults
    ) -> TunnelIntent {
        let intent = TunnelIntent(connect: connect, changedAt: date, source: source)
        if let data = try? encoder.encode(intent) {
            defaults?.set(data, forKey: key)
        }
        return intent
    }

    /// Whether a shared intent should override a decision this process made
    /// itself at `localChangedAt` (nil = this process never decided).
    static func supersedes(_ intent: TunnelIntent?, localChangedAt: Date?) -> Bool {
        guard let intent else {
            return false
        }
        guard let localChangedAt else {
            return true
        }
        return localChangedAt < intent.changedAt
    }

    // MARK: App-initiated stops

    /// The packet tunnel extension is told why it is being stopped, but a
    /// stop the app requested and a stop the user made in Settings (or with
    /// the system's VPN control) both arrive as `userInitiated`, and disabling
    /// the configuration first (which the app's stop path does) arrives as
    /// `configurationDisabled`. The app marks its own stops here just before
    /// it makes them; the extension consumes the mark, and treats an unmarked
    /// user stop as a shared disconnect intent.
    static let appStopKey = "network.ur.tunnel-intent.app-stop-at"

    /// How long an app stop mark stays valid.
    static let appStopWindow: TimeInterval = 30

    static func markAppInitiatedStop(at date: Date = Date(), in defaults: UserDefaults? = TunnelIntentStore.defaults) {
        defaults?.set(date.timeIntervalSince1970, forKey: appStopKey)
    }

    /// True when a stop the app marked within the window is pending; the
    /// mark is consumed either way.
    static func consumeAppInitiatedStop(
        now: Date = Date(),
        in defaults: UserDefaults? = TunnelIntentStore.defaults
    ) -> Bool {
        guard let defaults else {
            return false
        }
        let markedAt = defaults.double(forKey: appStopKey)
        defaults.removeObject(forKey: appStopKey)
        guard 0 < markedAt else {
            return false
        }
        return now.timeIntervalSince1970 - markedAt <= appStopWindow
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
