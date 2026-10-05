//
//  ProvidePausePolicyTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
#if os(iOS)
import UIKit
#endif
@testable import URnetwork

/**
 * Providing pauses for the battery (P077): the policy the packet tunnel
 * extension sets the provide pause from, the mode's storage and its provider
 * message, the pause reasons on the provider card, and the extension's
 * wiring.
 */
struct ProvidePausePolicyTests {

    private static func power(lowPower: Bool = false, charging: Bool? = false) -> ProvidePowerState {
        ProvidePowerState(lowPowerMode: lowPower, charging: charging)
    }

    // MARK: the policy

    @Test func theDefaultPausesInLowPowerMode() {
        #expect(ProvidePowerMode.defaultMode == .pauseInLowPower)
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: true), mode: .pauseInLowPower) == .lowPowerMode)
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: true, charging: true), mode: .pauseInLowPower) == .lowPowerMode)
        // on battery without Low Power Mode it provides
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: false, charging: false), mode: .pauseInLowPower) == nil)
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: false, charging: nil), mode: .pauseInLowPower) == nil)
    }

    @Test func alwaysNeverPausesForTheBattery() {
        for lowPower in [false, true] {
            for charging in [nil, false, true] as [Bool?] {
                #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: lowPower, charging: charging), mode: .always) == nil)
            }
        }
    }

    @Test func chargingOnlyPausesOnBattery() {
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(charging: false), mode: .chargingOnly) == .notCharging)
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(charging: true), mode: .chargingOnly) == nil)
        // and in Low Power Mode, as the default does
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: true, charging: true), mode: .chargingOnly) == .lowPowerMode)
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: true, charging: false), mode: .chargingOnly) == .lowPowerMode)
    }

    // a device that does not say whether it is charging never pauses on a guess
    @Test func anUnknownChargingStateDoesNotPause() {
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(charging: nil), mode: .chargingOnly) == nil)
        #expect(ProvidePausePolicy.powerPauseReason(power: Self.power(lowPower: true, charging: nil), mode: .chargingOnly) == .lowPowerMode)
    }

    // one decision from both sources, so neither clears the other's pause
    @Test func thePathAndTheBatteryCombine() {
        // the path alone
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: false, power: Self.power(), mode: .always) == .network)
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: true, power: Self.power(), mode: .always) == nil)
        // the battery alone
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: true, power: Self.power(lowPower: true), mode: .pauseInLowPower) == .lowPowerMode)
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: true, power: Self.power(charging: false), mode: .chargingOnly) == .notCharging)
        // both: still paused, the path first
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: false, power: Self.power(lowPower: true), mode: .pauseInLowPower) == .network)
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: false, power: Self.power(charging: false), mode: .chargingOnly) == .network)
        // neither
        #expect(ProvidePausePolicy.pauseReason(networkCanProvide: true, power: Self.power(charging: true), mode: .chargingOnly) == nil)
    }

    // MARK: the mode

    @Test func theModeIsStoredAndDefaultsToPausingInLowPowerMode() throws {
        let suite = "network.ur.tests.provide-power-mode.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        #expect(ProvidePowerModeStore.load(from: defaults) == .pauseInLowPower)
        for mode in ProvidePowerMode.allCases {
            ProvidePowerModeStore.save(mode, to: defaults)
            #expect(ProvidePowerModeStore.load(from: defaults) == mode)
        }
        // a value this build does not know reads as the default
        defaults.set("pause_in_battery_saver", forKey: ProvidePowerModeStore.key)
        #expect(ProvidePowerModeStore.load(from: defaults) == .pauseInLowPower)
    }

    @Test func theProviderMessageCarriesTheMode() {
        for mode in ProvidePowerMode.allCases {
            #expect(ProvidePowerModeMessage.decode(ProvidePowerModeMessage.encode(mode)) == mode)
        }
        #expect(String(data: ProvidePowerModeMessage.encode(.chargingOnly), encoding: .utf8) == "provide-power-mode:charging_only")
        // the extension's other messages are not a mode
        #expect(ProvidePowerModeMessage.decode(Data("flush-logs".utf8)) == nil)
        #expect(ProvidePowerModeMessage.decode(Data("logout".utf8)) == nil)
        #expect(ProvidePowerModeMessage.decode(Data("provide-power-mode:".utf8)) == nil)
        #expect(ProvidePowerModeMessage.decode(Data("provide-power-mode:sometimes".utf8)) == nil)
        #expect(ProvidePowerModeMessage.decode(Data([0xff, 0xfe])) == nil)
    }

    @Test func theModeLabelsAreTheStoreEnglish() {
        #expect(ProvidePowerMode.always.label.key == "Keep providing")
        #expect(ProvidePowerMode.pauseInLowPower.label.key == "Pause in Low Power Mode")
        #expect(ProvidePowerMode.chargingOnly.label.key == "Pause until charging")
    }

    // MARK: external power

    #if os(iOS)
    @Test func chargingOrFullIsExternalPower() {
        #expect(ProvideChargingMonitor.charging(batteryState: .charging) == true)
        #expect(ProvideChargingMonitor.charging(batteryState: .full) == true)
        #expect(ProvideChargingMonitor.charging(batteryState: .unplugged) == false)
        #expect(ProvideChargingMonitor.charging(batteryState: .unknown) == nil)
    }
    #elseif os(macOS)
    @Test func acPowerIsExternalPower() {
        #expect(ProvideChargingMonitor.charging(providingPowerSourceType: "AC Power") == true)
        #expect(ProvideChargingMonitor.charging(providingPowerSourceType: "Battery Power") == false)
        #expect(ProvideChargingMonitor.charging(providingPowerSourceType: "UPS Power") == false)
        #expect(ProvideChargingMonitor.charging(providingPowerSourceType: "") == nil)
    }
    #endif

    // MARK: the provider card

    private static func idleReason(
        _ controlMode: ProvideControlMode = .Always,
        live: Int = SdkProvideModePublic,
        paused: Bool,
        powerPause: ProvidePauseReason?,
        network: ProvideNetworkMode = .WiFi
    ) -> ProviderIdleReason {
        providerIdleReason(
            controlMode: controlMode,
            liveProvideMode: live,
            providePaused: paused,
            powerPauseReason: powerPause,
            provideNetworkMode: network,
            recentProviderBytes: 0
        )
    }

    // the device reports the pause; the power state says why
    @Test func aPausedDeviceSaysTheBatteryReason() {
        #expect(Self.idleReason(paused: true, powerPause: .lowPowerMode) == .pausedLowPower)
        #expect(Self.idleReason(paused: true, powerPause: .notCharging) == .pausedNotCharging)
        #expect(Self.idleReason(paused: true, powerPause: .lowPowerMode, network: .All) == .pausedLowPower)
        // without a battery reason the pause is the network's
        #expect(Self.idleReason(paused: true, powerPause: nil) == .pausedWifiOnly)
        #expect(Self.idleReason(paused: true, powerPause: nil, network: .All) == .pausedNoNetwork)
        #expect(Self.idleReason(paused: true, powerPause: .network, network: .All) == .pausedNoNetwork)
    }

    // a device that does not report the pause is not called paused
    @Test func aBatteryReasonNeedsThePause() {
        #expect(Self.idleReason(paused: false, powerPause: .lowPowerMode) == .noTrafficYet)
        #expect(Self.idleReason(paused: false, powerPause: .notCharging) == .noTrafficYet)
    }

    @Test func theModeStillWinsOverTheBattery() {
        #expect(Self.idleReason(.Auto, live: SdkProvideModeNetwork, paused: true, powerPause: .lowPowerMode) == .autoNotConnected)
        #expect(Self.idleReason(.Network, live: SdkProvideModeNetwork, paused: true, powerPause: .notCharging) == .networkOnly)
        #expect(Self.idleReason(.Never, live: SdkProvideModeNone, paused: true, powerPause: .lowPowerMode) == .none)
    }

    // the battery reasons are local, so they win over the cached server reason
    @Test func theBatteryReasonsWinOverTheServer() {
        for reason in [ProviderIdleReason.pausedLowPower, .pausedNotCharging] {
            #expect(providerStatusLine(idleReason: reason, serverReason: SdkProviderStatusReasonNotConnected, serverReasonText: "") == .idle(reason))
            #expect(providerStatusLine(idleReason: reason, serverReason: "", serverReasonText: "") == .idle(reason))
        }
    }

    @Test func theBatteryReasonsAreTheStoreEnglish() {
        #expect(ProviderIdleReason.pausedLowPower.text?.key == "Paused: Low Power Mode is on.")
        #expect(ProviderIdleReason.pausedNotCharging.text?.key == "Paused: this device isn't charging.")
    }

    @Test(arguments: ["de", "es", "ru", "ja"])
    func theNewStringsAreTranslated(_ locale: String) throws {
        let texts: [LocalizedStringResource] = [
            try #require(ProviderIdleReason.pausedLowPower.text),
            try #require(ProviderIdleReason.pausedNotCharging.text),
            ProvidePowerMode.always.label,
            ProvidePowerMode.pauseInLowPower.label,
            ProvidePowerMode.chargingOnly.label,
            "When on battery",
        ]
        for var text in texts {
            text.locale = Locale(identifier: locale)
            let translated = String(localized: text)
            #expect(!translated.isEmpty)
            #expect(translated != text.key, "\(locale) \(text.key)")
        }
    }

    // MARK: the extension

    // …/apple/app/networkTests/ProvidePausePolicyTests.swift -> …/apple/app/extension
    private static let extensionSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("extension/PacketTunnelProvider.swift")

    // the provide pause is set from the combined decision only, so a path
    // update cannot clear a battery pause (the tunnel start pauses until the
    // first decision)
    @Test func theExtensionSetsThePauseFromTheCombinedDecision() throws {
        let text = try String(contentsOf: Self.extensionSource, encoding: .utf8)
        let calls = text.components(separatedBy: "setProvidePaused(").dropFirst().map {
            String($0.prefix(while: { $0 != ")" }))
        }
        #expect(calls.sorted() == ["pauseReason != nil", "true"], "\(calls)")
        #expect(text.contains("ProvidePausePolicy.pauseReason("))
        #expect(!text.contains("setProvidePaused(!canProvideOnNetwork"))
    }

    // Low Power Mode, a charger and a new mode each re-decide the pause
    @Test func theExtensionRedecidesOnPowerChangesAndANewMode() throws {
        let text = try String(contentsOf: Self.extensionSource, encoding: .utf8)
        #expect(text.contains("NSProcessInfoPowerStateDidChange"))
        #expect(text.contains("ProvideChargingMonitor()"))
        #expect(text.contains("chargingMonitor.stop()"))
        #expect(text.contains("ProvidePowerModeMessage.decode(messageData)"))
        #expect(text.contains("ProvidePowerModeStore.save(mode)"))
        #expect(text.contains("ProvidePowerModeStore.load()"))
    }
}
