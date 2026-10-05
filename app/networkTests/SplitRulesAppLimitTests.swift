//
//  SplitRulesAppLimitTests.swift
//  networkTests
//
//  Users asked to keep apps (banking, local apps) off the VPN. iOS and macOS
//  allow per-app VPN only on devices an organization manages (MDM), so the
//  split rules screen now says why its rules match sites and addresses, how
//  to keep an app off the VPN anyway, and offers presets built from the
//  ranges a service publishes for use outside a VPN.
//
//  Reads the view and tunnel sources and the generated string catalog.
//

import Foundation
import Testing
@testable import URnetwork

struct SplitRulesAppLimitTests {

    private static let limit = "Split rules match sites and addresses, not apps: Apple allows per-app VPN only on devices managed by an organization (MDM). To keep an app off the VPN, route the sites it uses locally, or start from a preset. Local network addresses already bypass the VPN."

    private static let newStrings = [
        limit,
        "Start from a preset",
        "Ranges each service publishes for use outside a VPN",
        "Microsoft Teams calls",
        "Google Meet calls",
    ]

    // …/apple/app/networkTests/SplitRulesAppLimitTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theSplitRulesScreenSaysWhyRulesMatchSitesNotApps() throws {
        let view = try Self.source("network/Shared/Views/Stats/SplitRulesView.swift")
        #expect(view.contains("Text(\"\(Self.limit)\")"))
        #expect(view.contains("Text(\"Start from a preset\")"))
        #expect(view.contains("ForEach(SplitRulePreset.all)"))
    }

    /// The help text says local network addresses already bypass the VPN;
    /// that holds only while the tunnel leaves the private ranges out.
    @Test func localNetworkAddressesStayOutOfTheTunnel() throws {
        let tunnel = try Self.source("extension/PacketTunnelProvider.swift")
        #expect(tunnel.contains("NEIPv4Route(destinationAddress: \"10.0.0.0\", subnetMask: \"255.0.0.0\")"))
        #expect(tunnel.contains("NEIPv4Route(destinationAddress: \"172.16.0.0\", subnetMask: \"255.240.0.0\")"))
        #expect(tunnel.contains("NEIPv4Route(destinationAddress: \"192.168.0.0\", subnetMask: \"255.255.0.0\")"))
        #expect(tunnelIpv6Excluded("fe80::1"))
        #expect(tunnelIpv6Excluded("fd12:3456:789a::1"))
    }

    @Test func theNewStringsAreTranslatedInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        // every locale the catalog ships a translation for
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }

        for key in Self.newStrings {
            let entry = try #require(strings[key] as? [String: Any], "the catalog has no \(key)")
            #expect(entry["extractionState"] as? String != "stale")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(locale) has no \(key)")
                if locale != "en" {
                    #expect(value != key, "\(locale) \(key) is English")
                }
            }
        }
    }
}
