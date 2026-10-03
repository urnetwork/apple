//
//  KillSwitchExceptionCopyTests.swift
//  networkTests
//
//  The kill switch exception disclosure must match what the packet tunnel
//  installs. The tunnel is dual-stack and captures ::/0, so the disclosure must
//  not tell users that IPv6 bypasses the VPN (it said so after the dual-stack
//  tunnel landed). SMTP on port 25 is still a deliberate local route.
//

import Foundation
import Testing

struct KillSwitchExceptionCopyTests {

    // …/apple/app/networkTests/KillSwitchExceptionCopyTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theTunnelCapturesTheIpv6DefaultRoute() throws {
        let tunnel = try Self.source("extension/PacketTunnelProvider.swift")
        #expect(tunnel.contains("ipv6Settings.includedRoutes = [NEIPv6Route.default()]"))
        #expect(tunnel.contains("networkSettings.ipv6Settings = ipv6Settings"))
        // only local scopes are excluded; public IPv6 goes through the tunnel
        #expect(!tunnelIpv6Excluded("2606:4700:4700::1111"))
        #expect(!tunnelIpv6Excluded("2a00:1450:4001:80b::200e"))
    }

    @Test func theDisclosureDoesNotSayIpv6BypassesTheVpn() throws {
        let label = try Self.source("network/Shared/Views/Components/UrSwitchToggle.swift")
        #expect(!label.contains("IPv6 is not routed through URnetwork"))
        #expect(label.contains("IPv6 is routed through URnetwork like IPv4"))
        // the port 25 exception is real (connect ip_smtp_policy.go) and stays disclosed
        #expect(label.contains("SMTP on TCP port 25 bypasses the VPN"))
    }

    @Test func theCorrectedDisclosureIsLocalized() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let key = "While the VPN is connected, IPv6 is routed through URnetwork like IPv4. Outbound SMTP on TCP port 25 bypasses the VPN, even when the kill switch is on, which may expose your local public IP to those mail servers. SMTP on ports 465 and 587 stays in the VPN and must establish TLS."
        let entry = try #require(strings[key] as? [String: Any])
        #expect(entry["extractionState"] as? String != "stale")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        for locale in ["ar", "de", "es", "ru", "zh-Hans"] {
            #expect(localizations[locale] != nil, "\(locale) translation missing")
        }
    }
}
