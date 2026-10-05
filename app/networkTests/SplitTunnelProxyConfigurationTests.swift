//
//  SplitTunnelProxyConfigurationTests.swift
//  networkTests
//
//  The excluded apps travel from the app to the split tunnel system
//  extension twice: in the transparent proxy configuration's
//  providerConfiguration (read when the proxy starts) and as a provider
//  message (a change while it runs). These pin the encoding both sides
//  compile (network/Shared/SplitTunnel/SplitTunnelProxyConfiguration.swift)
//  and the normalization that keeps an equal list equal.
//

import Testing
import Foundation
@testable import URnetwork

struct SplitTunnelProxyConfigurationTests {

    @Test func theListIsTrimmedUniqueIgnoringCaseAndSorted() {
        let configuration = SplitTunnelProxyConfiguration(excludedApps: [
            " com.example.Zoom ",
            "com.example.bank",
            "COM.EXAMPLE.BANK",
            "com.example.Bank",
            "org.example.App",
        ])
        // the first spelling of a duplicate is kept
        #expect(configuration.excludedApps == ["com.example.bank", "com.example.Zoom", "org.example.App"])
    }

    @Test func aReorderedListIsTheSameConfiguration() {
        // so the app never rewrites the system's VPN preferences for an order
        #expect(SplitTunnelProxyConfiguration(excludedApps: ["b.example.app", "a.example.app"])
                == SplitTunnelProxyConfiguration(excludedApps: ["a.example.app", "b.example.app"]))
    }

    @Test func onlyIdentifierShapedValuesAreKept() {
        #expect(SplitTunnelProxyConfiguration.isValidIdentifier("com.example.App-2_beta"))
        #expect(SplitTunnelProxyConfiguration.isValidIdentifier("Tool"))
        for bad in ["", "com..example", ".com.example", "com.example.", "com example", "com/example", "com.éxample", "com.example*",
                    String(repeating: "a", count: 256)] {
            #expect(!SplitTunnelProxyConfiguration.isValidIdentifier(bad), "\(bad)")
        }
        let configuration = SplitTunnelProxyConfiguration(excludedApps: ["com..example", "", "com.example.App"])
        #expect(configuration.excludedApps == ["com.example.App"])
    }

    @Test func theListIsBounded() {
        let apps = (0..<1000).map { "com.example.app\($0)" }
        #expect(SplitTunnelProxyConfiguration(excludedApps: apps).excludedApps.count == SplitTunnelProxyConfiguration.maximumExcludedApps)
    }

    @Test func theProviderConfigurationRoundTrips() {
        let configuration = SplitTunnelProxyConfiguration(excludedApps: ["com.example.Bank", "us.zoom.xos"])
        let dictionary = configuration.providerConfiguration
        #expect(dictionary["version"] as? Int == SplitTunnelProxyConfiguration.version)
        #expect(dictionary["excluded_apps"] as? [String] == ["com.example.Bank", "us.zoom.xos"])
        #expect(SplitTunnelProxyConfiguration(providerConfiguration: dictionary) == configuration)
    }

    @Test func aProviderConfigurationWithoutAListIsNotOne() {
        #expect(SplitTunnelProxyConfiguration(providerConfiguration: nil) == nil)
        #expect(SplitTunnelProxyConfiguration(providerConfiguration: [:]) == nil)
        #expect(SplitTunnelProxyConfiguration(providerConfiguration: ["excluded_apps": "com.example.Bank"]) == nil)
        // an empty list is a list
        #expect(SplitTunnelProxyConfiguration(providerConfiguration: ["excluded_apps": [String]()]) == .empty)
    }

    @Test func entriesThatAreNotStringsAreDropped() {
        let configuration = SplitTunnelProxyConfiguration(providerConfiguration: [
            "excluded_apps": ["com.example.Bank", 7, ["nested"], "com.example.Other"] as [Any],
        ])
        #expect(configuration?.excludedApps == ["com.example.Bank", "com.example.Other"])
    }

    @Test func theProviderMessageRoundTrips() {
        let configuration = SplitTunnelProxyConfiguration(excludedApps: ["com.example.Bank"])
        let data = configuration.messageData
        #expect(!data.isEmpty)
        #expect(SplitTunnelProxyConfiguration(messageData: data) == configuration)
        #expect(SplitTunnelProxyConfiguration(messageData: SplitTunnelProxyConfiguration.empty.messageData) == .empty)
    }

    @Test func anUnreadableMessageIsIgnored() {
        #expect(SplitTunnelProxyConfiguration(messageData: Data()) == nil)
        #expect(SplitTunnelProxyConfiguration(messageData: Data("not json".utf8)) == nil)
        #expect(SplitTunnelProxyConfiguration(messageData: Data("[\"com.example.Bank\"]".utf8)) == nil)
        #expect(SplitTunnelProxyConfiguration(messageData: Data("{\"excluded_apps\": 1}".utf8)) == nil)
    }
}
