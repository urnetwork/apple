//
//  FastDnsOnConnectTests.swift
//  networkTests
//
//  The host-network dns fallback is the opt-in "Fast DNS on connect" toggle,
//  off by default, so dns resolves only through the tunnel unless the user
//  turns it on.
//
//  The app reaches that default through two paths the tests pin: the editor
//  and drawer read the sdk settings through DnsSettings, and
//  DeviceManager.initDevice seeds the next device from the app's mirror of
//  the settings. A mirror an older build wrote carries the old default
//  (fallback on) in a record that cannot tell it apart from a user choice,
//  so it must read back off; a choice this build writes must survive.
//

import Testing
import Foundation
import URnetworkSdk
@testable import URnetwork

struct FastDnsOnConnectTests {

    private func withLocalStateHome(_ body: (URL, SdkLocalState) throws -> Void) rethrows {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastDnsOnConnectTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        guard let asyncLocalState = SdkAsyncLocalState(home.path()),
              let localState = asyncLocalState.getLocalState() else {
            Issue.record("could not open a local state under \(home.path())")
            return
        }
        defer { asyncLocalState.close() }
        try body(home, localState)
    }

    @Test func theDefaultSettingsResolveOnlyThroughTheTunnel() throws {
        let defaults = try #require(SdkGetDefaultDnsResolverSettings())
        let settings = DnsSettings(defaults)
        #expect(!settings.fastDnsOnConnectEnabled, "the default dns settings race the host network")
        #expect(!settings.localDnsEnabled)
        #expect(settings.dohEnabled)
    }

    @Test func aBlankFormHasFastDnsOff() {
        #expect(!DnsSettings().fastDnsOnConnectEnabled)
        #expect(!DnsSettings().toSdk().enableFallback)
    }

    @Test func theToggleFollowsTheSdkFallbackBothWays() {
        for enabled in [true, false] {
            let sdkSettings = SdkDnsResolverSettings()
            sdkSettings.enableRemoteDoh = true
            sdkSettings.enableFallback = enabled

            let settings = DnsSettings(sdkSettings)
            #expect(settings.fastDnsOnConnectEnabled == enabled)
            #expect(settings.toSdk().enableFallback == enabled)
        }
    }

    /// A mirror exactly as an older build wrote it: the whole settings object
    /// with the fallback on and no opt-in version.
    @Test func aMirrorWithTheOldDefaultReadsBackWithFastDnsOff() throws {
        try withLocalStateHome { home, localState in
            let legacy = """
            {"EnableRemoteDoh":true,"EnableLocalDoh":false,"EnableRemoteDns":false,"EnableLocalDns":false,\
            "EnableFallback":true,"DnsUpgradeMaskAddress":"",\
            "RemoteDohUrlsIpv4":["https://doh.example/dns-query"],"RemoteDohUrlsIpv6":[],\
            "LocalDohUrlsIpv4":[],"LocalDohUrlsIpv6":[],"RemoteDnsIpv4":[],"RemoteDnsIpv6":[],\
            "LocalDnsIpv4":[],"LocalDnsIpv6":[]}
            """
            try Data(legacy.utf8).write(to: home.appendingPathComponent(".by/.dns_resolver_settings"))

            let read = try #require(localState.getDnsResolverSettings())
            let settings = DnsSettings(read)
            #expect(!settings.fastDnsOnConnectEnabled, "a pre-opt-in mirror seeded the device with the host-network fallback on")
            #expect(settings.remoteDohUrlsIpv4 == ["https://doh.example/dns-query"])
        }
    }

    @Test func anExplicitOptInSurvivesTheMirror() throws {
        try withLocalStateHome { _, localState in
            var settings = DnsSettings()
            settings.enableRemoteDoh = true
            settings.enableFallback = true
            try localState.setDnsResolverSettings(settings.toSdk())

            let read = try #require(localState.getDnsResolverSettings())
            #expect(DnsSettings(read).fastDnsOnConnectEnabled)
        }
    }
}
