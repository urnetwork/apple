//
//  DnsResolverSettingsMirrorTests.swift
//  networkTests
//
//  Covers the store the dns resolver settings are mirrored into.
//
//  The settings themselves live in the network extension's container, which
//  the app process cannot read, so this mirror is the app's only durable copy
//  -- it is what the editor opens on with the tunnel down and what
//  DeviceManager.initDevice seeds the next device from.
//
//  The distinction the fix would be silently wrong without: writing nil
//  DELETES the store, and a deleted store reads back exactly like one that was
//  never written, so "the user turned everything off" and "this install has
//  never mirrored" are the same value unless an emptied form is written as a
//  settings object. Read as never-mirrored it would restore the resolver the
//  user just cleared; read as emptied it would push a blank resolver over the
//  one the extension still holds. DnsSettingsStore.persist and the seed's
//  `if let` both rest on that line.
//

import Testing
import Foundation
import URnetworkSdk
@testable import URnetwork

struct DnsResolverSettingsMirrorTests {

    /// Each test gets its own storage home; the SDK roots the store at
    /// `<home>/.by`, so a fresh temporary directory is a fresh store.
    private func withLocalState(_ body: (SdkLocalState) throws -> Void) rethrows {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DnsResolverSettingsMirrorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        guard let asyncLocalState = SdkAsyncLocalState(home.path()),
              let localState = asyncLocalState.getLocalState() else {
            Issue.record("could not open a local state under \(home.path())")
            return
        }
        defer { asyncLocalState.close() }
        try body(localState)
    }

    /// a configuration with both a toggle set and servers in more than one
    /// list, so a round trip that drops either shows up
    private var configured: DnsSettings {
        var settings = DnsSettings()
        settings.enableRemoteDoh = true
        settings.enableLocalDns = true
        settings.enableFallback = true
        settings.remoteDohUrlsIpv4 = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]
        settings.remoteDohUrlsIpv6 = ["https://[2606:4700:4700::1111]/dns-query"]
        settings.localDnsIpv4 = ["192.168.1.1"]
        settings.localDnsIpv6 = ["fe80::1"]
        return settings
    }

    /// Every field the editor writes and the connect drawer summarizes --
    /// settings that round-trip without them render as a resolver the user
    /// never configured.
    @Test func settingsRoundTripWithTheirTogglesAndServers() throws {
        try withLocalState { localState in
            let configured = self.configured

            try localState.setDnsResolverSettings(configured.toSdk())

            let read = try #require(localState.getDnsResolverSettings())
            #expect(DnsSettings(read) == configured)
        }
    }

    /// The mirror copies the device's own settings object rather than the
    /// DnsSettings projection the editor renders, so fields the app never
    /// models have to survive it too.
    @Test func fieldsTheAppDoesNotModelSurviveTheRoundTrip() throws {
        try withLocalState { localState in
            let sdkSettings = configured.toSdk()
            sdkSettings.dnsUpgradeMaskAddress = "10.64.0.1"

            try localState.setDnsResolverSettings(sdkSettings)

            let read = try #require(localState.getDnsResolverSettings())
            #expect(read.dnsUpgradeMaskAddress == "10.64.0.1")
        }
    }

    /// "I turned everything off" -- an emptied form is a real value and has to
    /// come back as one, or the seed skips it and the extension's resolver
    /// stands.
    @Test func settingsWithNothingEnabledRoundTripAsAValue() throws {
        try withLocalState { localState in
            try localState.setDnsResolverSettings(configured.toSdk())
            try localState.setDnsResolverSettings(DnsSettings().toSdk())

            let read = try #require(localState.getDnsResolverSettings())
            #expect(DnsSettings(read) == DnsSettings())
        }
    }

    /// Writing nil is the delete branch. DnsSettingsStore.persist must never
    /// reach it: the result is indistinguishable from an install that never
    /// mirrored.
    @Test func writingNilDeletesTheStore() throws {
        try withLocalState { localState in
            try localState.setDnsResolverSettings(configured.toSdk())
            #expect(localState.getDnsResolverSettings() != nil)

            try localState.setDnsResolverSettings(nil)

            #expect(localState.getDnsResolverSettings() == nil)
        }
    }

    /// The upgrade guard. A build that has never mirrored reads nil, so
    /// DeviceManager.initDevice queues nothing and the resolver a pre-fix build
    /// left in the extension is still there on the first launch after this
    /// ships -- rather than being replaced by a blank one.
    @Test func aStoreThatWasNeverWrittenReadsNilRatherThanEmptySettings() throws {
        try withLocalState { localState in
            #expect(localState.getDnsResolverSettings() == nil)
        }
    }
}
