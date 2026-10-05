//
//  ProviderIdleReasonTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The line under the provide mode row that says why an enabled provider is
 * idle (P008): every row of the decision table, the precedences between
 * them, and the text of each reason.
 */
struct ProviderIdleReasonTests {

    private static func reason(
        _ controlMode: ProvideControlMode?,
        live: Int = SdkProvideModePublic,
        paused: Bool = false,
        network: ProvideNetworkMode = .All,
        bytes: Int64 = 1024
    ) -> ProviderIdleReason {
        providerIdleReason(
            controlMode: controlMode,
            liveProvideMode: live,
            providePaused: paused,
            provideNetworkMode: network,
            recentProviderBytes: bytes
        )
    }

    // MARK: the table

    // 1: Never, or a mode this build does not know, says nothing
    @Test func neverAndUnknownModesSayNothing() {
        #expect(Self.reason(.Never) == .none)
        #expect(Self.reason(.Never, live: SdkProvideModeNone, bytes: 0) == .none)
        #expect(Self.reason(nil) == .none)
        #expect(Self.reason(nil, live: SdkProvideModeNetwork, paused: true, network: .WiFi, bytes: 0) == .none)
        // the sdk's manual mode does not parse into a mode the app shows
        #expect(ProvideControlMode(rawValue: "manual") == nil)
        #expect(Self.reason(ProvideControlMode(rawValue: "manual"), bytes: 0) == .none)
    }

    // 2: Network provides only to the user's own devices
    @Test func networkProvidesOnlyToOwnDevices() {
        #expect(Self.reason(.Network, live: SdkProvideModeNetwork) == .networkOnly)
        #expect(Self.reason(.Network, live: SdkProvideModePublic, bytes: 0) == .networkOnly)
    }

    // 3: Auto shares with everyone only while connected
    @Test func autoWhileDisconnectedIsNotSharedWithEveryone() {
        #expect(Self.reason(.Auto, live: SdkProvideModeNetwork) == .autoNotConnected)
        #expect(Self.reason(.Auto, live: SdkProvideModeNone) == .autoNotConnected)
        #expect(Self.reason(.Auto, live: SdkProvideModeFriendsAndFamily) == .autoNotConnected)
        // connected, Auto is public and reads like Always
        #expect(Self.reason(.Auto, live: SdkProvideModePublic) == .none)
        #expect(Self.reason(.Auto, live: SdkProvideModePublic, bytes: 0) == .noTrafficYet)
    }

    // 4: paused on a Wi-Fi only setting
    @Test func pausedOnWifiOnly() {
        #expect(Self.reason(.Always, paused: true, network: .WiFi) == .pausedWifiOnly)
        #expect(Self.reason(.Auto, paused: true, network: .WiFi) == .pausedWifiOnly)
    }

    // 5: paused otherwise
    @Test func pausedWithoutWifiOnly() {
        #expect(Self.reason(.Always, paused: true, network: .All) == .pausedNoNetwork)
        #expect(Self.reason(.Auto, paused: true, network: .All, bytes: 0) == .pausedNoNetwork)
    }

    // 6: public, not paused, and nothing relayed in the window
    @Test func publicWithoutTrafficIsNoTrafficYet() {
        #expect(Self.reason(.Always, bytes: 0) == .noTrafficYet)
        #expect(Self.reason(.Always, network: .WiFi, bytes: 0) == .noTrafficYet)
    }

    // 7: otherwise nothing to explain
    @Test func publicWithTrafficSaysNothing() {
        #expect(Self.reason(.Always, bytes: 1) == .none)
        #expect(Self.reason(.Always, network: .WiFi, bytes: 1) == .none)
        // Always that is not live public yet (the device has not applied it)
        // has no reason of its own
        #expect(Self.reason(.Always, live: SdkProvideModeNone, bytes: 0) == .none)
    }

    // MARK: precedences

    @Test func autoDisconnectedWinsOverAPause() {
        #expect(Self.reason(.Auto, live: SdkProvideModeNetwork, paused: true, network: .WiFi, bytes: 0) == .autoNotConnected)
    }

    @Test func networkWinsOverAPause() {
        #expect(Self.reason(.Network, live: SdkProvideModeNetwork, paused: true, network: .WiFi, bytes: 0) == .networkOnly)
    }

    @Test func neverWinsOverAPause() {
        #expect(Self.reason(.Never, live: SdkProvideModeNone, paused: true, network: .WiFi, bytes: 0) == .none)
    }

    @Test func aPauseWinsOverNoTraffic() {
        #expect(Self.reason(.Always, paused: true, network: .WiFi, bytes: 0) == .pausedWifiOnly)
        #expect(Self.reason(.Always, paused: true, network: .All, bytes: 0) == .pausedNoNetwork)
        // paused with bytes still in the window
        #expect(Self.reason(.Always, paused: true, network: .All, bytes: 4096) == .pausedNoNetwork)
    }

    // MARK: the text

    // the English is the catalog key, so it must be the store's source text
    @Test func eachReasonHasTheStoreEnglish() {
        let english: [ProviderIdleReason: String] = [
            .autoNotConnected: "Auto shares with everyone only while you're connected. Choose Always to earn while idle.",
            .networkOnly: "Shared only with your own devices. Choose Always to share with everyone.",
            .pausedWifiOnly: "Paused: providing is set to Wi-Fi only, and this device isn't on Wi-Fi.",
            .pausedNoNetwork: "Paused: this device can't provide on its current network.",
            .noTrafficYet: "New providers need several hours of steady uptime and a speed test before clients are sent to them. Traffic also depends on demand in your region.",
        ]
        #expect(ProviderIdleReason.none.text == nil)
        for reason in ProviderIdleReason.allCases where reason != .none {
            #expect(reason.text?.key == english[reason], "\(reason)")
        }
        #expect(Set(english.keys) == Set(ProviderIdleReason.allCases.filter { $0 != .none }))
    }

    // a translation is found only when the English matches the catalog key
    @Test(arguments: ["de", "es", "ru"])
    func eachReasonIsTranslated(_ locale: String) throws {
        for reason in ProviderIdleReason.allCases where reason != .none {
            var text = try #require(reason.text)
            text.locale = Locale(identifier: locale)
            let translated = String(localized: text)
            #expect(!translated.isEmpty)
            #expect(translated != text.key, "\(locale) \(reason)")
        }
    }

    // MARK: inputs

    // the Wi-Fi only setting is read only where the extension applies it
    @Test func theNetworkModeFollowsTheCellularSetting() {
        #if os(iOS)
        if #available(iOS 18, *) {
            #expect(providerIdleNetworkMode(allowProvidingCell: false) == .WiFi)
            #expect(providerIdleNetworkMode(allowProvidingCell: true) == .All)
            return
        }
        #endif
        #expect(providerIdleNetworkMode(allowProvidingCell: false) == .All)
        #expect(providerIdleNetworkMode(allowProvidingCell: true) == .All)
    }
}
