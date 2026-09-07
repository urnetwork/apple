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

// Origin metadata, not credentials or an authentication authority. Required
// stable identifiers bind intent to the accepted client; optional account
// claims only detect known conflicts. A normal omitted-to-known claim refresh
// must not manufacture an account change.
struct TunnelIntentOwner: Codable, Equatable {
    let instanceId: String
    let clientId: String
    let hostName: String
    let envName: String
    let networkId: String?
    let userId: String?
    let deviceId: String?

    func matches(_ other: TunnelIntentOwner) -> Bool {
        guard Self.identifier(instanceId) != nil,
              Self.identifier(clientId) != nil,
              !hostName.isEmpty,
              instanceId == other.instanceId,
              clientId == other.clientId,
              hostName == other.hostName,
              envName == other.envName else { return false }
        for pair in [(networkId, other.networkId), (userId, other.userId), (deviceId, other.deviceId)] {
            if let lhs = Self.identifier(pair.0), let rhs = Self.identifier(pair.1), lhs != rhs {
                return false
            }
        }
        return true
    }

    static func make(
        instanceId: String,
        clientJwt: String,
        networkSpaceJson: String
    ) -> TunnelIntentOwner? {
        guard let instanceId = identifier(instanceId),
              let claims = clientClaims(clientJwt),
              let clientId = identifier(claims["client_id"] as? String),
              let data = networkSpaceJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? [String: Any],
              let hostName = key["host_name"] as? String, !hostName.isEmpty else { return nil }
        // NetworkSpaceKey preserves the host and normalizes an empty env to
        // main, otherwise lowercase. Do not store the exported values/secrets.
        let rawEnv = key["env_name"] as? String ?? ""
        let envName = rawEnv.isEmpty ? "main" : rawEnv.lowercased()
        return TunnelIntentOwner(
            instanceId: instanceId, clientId: clientId,
            hostName: hostName, envName: envName,
            networkId: identifier(claims["network_id"] as? String),
            userId: identifier(claims["user_id"] as? String),
            deviceId: identifier(claims["device_id"] as? String)
        )
    }

    static func fromProviderConfiguration(_ configuration: [String: Any]) -> TunnelIntentOwner? {
        guard let instanceId = configuration["instance_id"] as? String,
              let clientJwt = configuration["by_jwt"] as? String,
              let networkSpaceJson = configuration["network_space"] as? String else { return nil }
        return make(instanceId: instanceId, clientJwt: clientJwt, networkSpaceJson: networkSpaceJson)
    }

    // Reads only the client token supplied by an accepted device or existing
    // profile. Parsing metadata is not signature validation; SDK/server auth
    // remains mandatory before any tunnel routing is adopted.
    private static func clientClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["client_id", "network_id", "user_id", "device_id"] {
            if let value = claims[key], !(value is String) { return nil }
        }
        return claims
    }

    private static func identifier(_ value: String?) -> String? {
        guard let value, let id = UUID(uuidString: value), id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { return nil }
        return id.uuidString.lowercased()
    }
}

struct TunnelIntent: Codable, Equatable {

    /// true = the user asked for the tunnel to be up.
    var connect: Bool

    /// When the decision was made.
    var changedAt: Date

    /// Who recorded it, for diagnostics: see the `TunnelIntentStore.source*`
    /// constants.
    var source: String

    /// Optional for records written by older versions. Unscoped connect
    /// records cannot authorize a fresh destination in another process.
    var owner: TunnelIntentOwner? = nil

    func applies(to currentOwner: TunnelIntentOwner?) -> Bool {
        if let owner, let currentOwner { return owner.matches(currentOwner) }
        return owner == nil && !connect
    }
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
        try? loadChecked(from: defaults)
    }

    // A corrupt or unavailable shared store is not an absent connect intent.
    // Recovery callers fail closed; display-only compatibility readers may
    // continue using load().
    static func loadChecked(from defaults: UserDefaults? = TunnelIntentStore.defaults) throws -> TunnelIntent? {
        guard let defaults else { throw TunnelIntentStorageError.unavailable }
        guard let object = defaults.object(forKey: key) else {
            return nil
        }
        guard let data = object as? Data else { throw TunnelIntentStorageError.malformed }
        return try decoder.decode(TunnelIntent.self, from: data)
    }

    @discardableResult
    static func record(
        connect: Bool,
        source: String,
        owner: TunnelIntentOwner? = nil,
        at date: Date = Date(),
        in defaults: UserDefaults? = TunnelIntentStore.defaults
    ) -> TunnelIntent {
        let intent = TunnelIntent(connect: connect, changedAt: date, source: source, owner: owner)
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

enum TunnelIntentStorageError: Error {
    case unavailable
    case malformed
}
