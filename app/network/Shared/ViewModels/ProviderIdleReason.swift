//
//  ProviderIdleReason.swift
//  URnetwork
//
//  Why a provider that is enabled earns nothing, as one muted line under the
//  provide mode row (P008). The provider charts show while providing is
//  enabled whatever the device is doing, so an idle provider saw an empty
//  chart with no reason and read it as "the app doesn't pay". Kept pure so it
//  is unit testable.
//

import Foundation
import URnetworkSdk

/// Why an enabled provider is idle. `none` shows no line.
enum ProviderIdleReason: Equatable, CaseIterable {
    case none
    /// Auto provides to everyone only while this device's VPN is connected.
    /// Disconnected, the sdk provides only to the user's own devices
    /// (`applyProvideControlModeWithLock`), and the charts and the green dot
    /// still read as providing.
    case autoNotConnected
    case networkOnly
    case pausedWifiOnly
    /// The extension pauses whenever its path cannot provide: no network, a
    /// constrained (Low Data Mode) or expensive Wi-Fi path, cellular without
    /// "all", and always below iOS 18 / macOS 15 (`canProvideOnNetwork`).
    /// The text stays true in every one of those cases.
    case pausedNoNetwork
    case noTrafficYet
}

/// The idle reason from the live provide state. The first match wins:
/// a mode that is not shared with everyone, then a pause, then no traffic.
///
/// - Parameters:
///   - controlMode: the provide mode the user picked; nil when the device
///     reports a mode this build does not know (the sdk's `manual`)
///   - liveProvideMode: the device's live provide mode (`SdkProvideMode*`)
///   - providePaused: whether the device paused providing
///   - provideNetworkMode: `.WiFi` when providing is set to Wi-Fi only
///   - recentProviderBytes: the bytes this device relayed in the throughput
///     window
func providerIdleReason(
    controlMode: ProvideControlMode?,
    liveProvideMode: Int,
    providePaused: Bool,
    provideNetworkMode: ProvideNetworkMode,
    recentProviderBytes: Int64
) -> ProviderIdleReason {
    switch controlMode {
    case .Never, nil:
        // "Providing is disabled" already covers Never
        return .none
    case .Network:
        return .networkOnly
    case .Auto where liveProvideMode != SdkProvideModePublic:
        return .autoNotConnected
    case .Auto, .Always:
        break
    }
    if providePaused {
        return provideNetworkMode == .WiFi ? .pausedWifiOnly : .pausedNoNetwork
    }
    if liveProvideMode == SdkProvideModePublic && recentProviderBytes == 0 {
        return .noTrafficYet
    }
    return .none
}

/// The provide network mode the idle reason reads. Only the iOS 18+
/// extension provides on a Wi-Fi only setting: macOS has no Wi-Fi only setting
/// to change, and below iOS 18 the extension never provides, so neither pause
/// is about Wi-Fi.
func providerIdleNetworkMode(allowProvidingCell: Bool) -> ProvideNetworkMode {
    #if os(iOS)
    if #available(iOS 18, *) {
        return allowProvidingCell ? .All : .WiFi
    }
    #endif
    return .All
}

extension ProviderIdleReason {

    /// The line under the provide mode row, nil for none. The English is the
    /// catalog key (localizations `provider_idle_*`).
    var text: LocalizedStringResource? {
        switch self {
        case .none:
            return nil
        case .autoNotConnected:
            return "Auto shares with everyone only while you're connected. Choose Always to earn while idle."
        case .networkOnly:
            return "Shared only with your own devices. Choose Always to share with everyone."
        case .pausedWifiOnly:
            return "Paused: providing is set to Wi-Fi only, and this device isn't on Wi-Fi."
        case .pausedNoNetwork:
            return "Paused: this device can't provide on its current network."
        case .noTrafficYet:
            return "New providers need several hours of steady uptime and a speed test before clients are sent to them. Traffic also depends on demand in your region."
        }
    }
}
