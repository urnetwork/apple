//
//  ProvidePausePolicy.swift
//  URnetwork
//
//  When providing pauses for the battery (P077). Providing kept a phone or
//  laptop busy on battery, also in Low Power Mode: the extension paused only
//  for its network path. The packet tunnel extension now sets the provide
//  pause from one decision that combines the path with the battery, so a path
//  update cannot clear a battery pause and a charger cannot clear a network
//  pause; the app reads the same policy to say why providing is paused.
//
//  Compiled into the app and the packet tunnel extensions (listed explicitly
//  in their sources phases). No SDK import, on purpose.
//

import Foundation

/// What providing does while this device runs on battery. The user's choice
/// is kept with the app, not the network space: it is about this device's
/// battery, not the account.
enum ProvidePowerMode: String, CaseIterable, Identifiable {
    /// keep providing on battery, also in Low Power Mode
    case always = "always"
    /// pause while Low Power Mode is on (the default)
    case pauseInLowPower = "pause_in_low_power"
    /// provide only on external power, and pause in Low Power Mode
    case chargingOnly = "charging_only"

    static let defaultMode: ProvidePowerMode = .pauseInLowPower

    var id: Self { self }
}

/// Why providing is paused.
enum ProvidePauseReason: String {
    /// the path cannot provide (canProvideOnNetwork): no network, Wi-Fi only
    /// off Wi-Fi, Low Data Mode, an expensive Wi-Fi path
    case network = "network"
    case lowPowerMode = "low_power_mode"
    case notCharging = "not_charging"
}

/// The power facts providing reads.
struct ProvidePowerState: Equatable {
    var lowPowerMode: Bool
    /// on external power (charging, or full and plugged in); nil when the
    /// device does not say, which never pauses providing on a guess
    var charging: Bool?
}

enum ProvidePausePolicy {

    /// The battery's reason to pause providing, nil to provide.
    static func powerPauseReason(power: ProvidePowerState, mode: ProvidePowerMode) -> ProvidePauseReason? {
        if mode == .always {
            return nil
        }
        if power.lowPowerMode {
            return .lowPowerMode
        }
        if mode == .chargingOnly && power.charging == false {
            return .notCharging
        }
        return nil
    }

    /// The one decision the provide pause is set from: the path first, then
    /// the battery. nil to provide.
    static func pauseReason(
        networkCanProvide: Bool,
        power: ProvidePowerState,
        mode: ProvidePowerMode
    ) -> ProvidePauseReason? {
        if !networkCanProvide {
            return .network
        }
        return powerPauseReason(power: power, mode: mode)
    }
}

/// The provider message that hands the power mode to the packet tunnel
/// extension. It works for every tunnel type, the macOS system extension
/// included, which cannot read the user's shared stores.
enum ProvidePowerModeMessage {

    static let prefix = "provide-power-mode:"

    static func encode(_ mode: ProvidePowerMode) -> Data {
        Data("\(prefix)\(mode.rawValue)".utf8)
    }

    /// The mode a message carries, nil for any other message.
    static func decode(_ messageData: Data) -> ProvidePowerMode? {
        guard let message = String(data: messageData, encoding: .utf8),
              message.hasPrefix(prefix) else {
            return nil
        }
        return ProvidePowerMode(rawValue: String(message.dropFirst(prefix.count)))
    }
}

/// Where each process keeps the power mode: the app keeps the user's choice,
/// and the extension keeps the last mode the app sent, so a tunnel that
/// starts while the app is closed applies it.
enum ProvidePowerModeStore {

    static let key = "network.ur.provide-power-mode"

    static func load(from defaults: UserDefaults = .standard) -> ProvidePowerMode {
        defaults.string(forKey: key).flatMap { ProvidePowerMode(rawValue: $0) } ?? .defaultMode
    }

    static func save(_ mode: ProvidePowerMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
