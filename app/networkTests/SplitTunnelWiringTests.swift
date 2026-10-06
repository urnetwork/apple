//
//  SplitTunnelWiringTests.swift
//  networkTests
//
//  The macOS per-app split tunnel spans files no unit test can run: the
//  system extension's plists and entitlements, its provider, and the Apps
//  section of the split rules screen. These read them and check they agree
//  with each other and with TunnelProviderIdentity, and that every string
//  the section shows is translated. test-direct-bundle-ids_test.go in the
//  repo root checks the same identifiers in project.pbxproj.
//

import Foundation
import Testing
@testable import URnetwork

struct SplitTunnelWiringTests {

    private static let newStrings = [
        "Split rules match sites and addresses. To keep an app off the VPN on this Mac, add it under Apps. Local network addresses already bypass the VPN.",
        "Apps",
        "Apps listed here bypass the VPN.",
        "Add an app",
        "Search apps",
        "No apps found",
        "To keep these apps off the VPN, allow the URnetwork Split Tunnel extension in System Settings.",
        "Open System Settings",
        "These apps can't bypass the VPN right now. Retry, and allow the proxy configuration if macOS asks.",
    ]

    // …/apple/app/networkTests/SplitTunnelWiringTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent(path))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: the extension

    /// Both families' extensions declare the transparent proxy, under a mach
    /// service their own app group prefixes, with the provider entitlement
    /// their distribution needs.
    @Test(arguments: [
        ("splittunnel/Info.plist", "splittunnel/splittunnel.entitlements", TunnelProviderIdentity.appStore, "app-proxy-provider"),
        ("splittunnel/Info-direct.plist", "splittunnel/splittunnel-direct.entitlements", TunnelProviderIdentity.direct, "app-proxy-provider-systemextension"),
    ])
    func theExtensionDeclaresTheTransparentProxy(
        info: String,
        entitlements: String,
        family: TunnelProviderIdentity.Set,
        providerEntitlement: String
    ) throws {
        let network = try #require(try Self.plist(info)["NetworkExtension"] as? [String: Any])
        let classes = try #require(network["NEProviderClasses"] as? [String: String])
        #expect(classes == ["com.apple.networkextension.app-proxy": "$(PRODUCT_MODULE_NAME).SplitTunnelProxyProvider"])

        let granted = try Self.plist(entitlements)
        let groups = try #require(granted["com.apple.security.application-groups"] as? [String])
        #expect(groups == ["6BGU69Q742." + family.appGroupBase])
        #expect(network["NEMachServiceName"] as? String == "6BGU69Q742." + family.appGroupBase + ".splittunnel")
        #expect(granted["com.apple.developer.networking.networkextension"] as? [String] == [providerEntitlement])
        // it runs as root and reads only its configuration
        #expect(granted["keychain-access-groups"] == nil)
    }

    @Test func theExtensionIdentifierIsTheAppsPlusSplitTunnel() {
        for family in [TunnelProviderIdentity.appStore, TunnelProviderIdentity.direct] {
            #expect(family.splitTunnelBundleIdentifier == family.appBundleIdentifier + ".splittunnel")
        }
        #expect(TunnelProviderIdentity.splitTunnelBundleIdentifier == TunnelProviderIdentity.flavor.splitTunnelBundleIdentifier)
    }

    /// The apps may configure a transparent proxy and install a system
    /// extension; the direct build already could do the latter.
    @Test func theAppsMayConfigureTheProxy() throws {
        let store = try Self.plist("network/network-macOS.entitlements")
        #expect((store["com.apple.developer.networking.networkextension"] as? [String])?.contains("app-proxy-provider") == true)
        #expect(store["com.apple.developer.system-extension.install"] as? Bool == true)
        let direct = try Self.plist("network/network-macOS-direct.entitlements")
        #expect((direct["com.apple.developer.networking.networkextension"] as? [String])?.contains("app-proxy-provider-systemextension") == true)
        #expect(direct["com.apple.developer.system-extension.install"] as? Bool == true)
        // the iOS build has no transparent proxy
        let ios = try Self.plist("network/network.entitlements")
        #expect((ios["com.apple.developer.networking.networkextension"] as? [String])?.contains("app-proxy-provider") == false)
    }

    @Test func theProviderDecidesWithTheSharedDecision() throws {
        let provider = try Self.source("splittunnel/SplitTunnelProxyProvider.swift")
        #expect(provider.contains("final class SplitTunnelProxyProvider: NETransparentProxyProvider, NEAppProxyUDPFlowHandling"))
        #expect(provider.contains("SplitTunnelFlowDecision.verdict("))
        #expect(provider.contains("SplitTunnelProxyConfiguration(messageData: messageData)"))
        #expect(provider.contains("protocol: .TCP"))
        #expect(provider.contains("protocol: .UDP"))
        let relays = try Self.source("splittunnel/SplitTunnelRelays.swift")
        #expect(relays.contains("parameters.prohibitedInterfaceTypes = [.other]"))
    }

    @Test func theControllerConfiguresTheSplitTunnelExtension() throws {
        let controller = try Self.source("network/Shared/SplitTunnel/SplitTunnelProxyController.swift")
        #expect(controller.contains("extensionBundleIdentifier: TunnelProviderIdentity.splitTunnelBundleIdentifier"))
        #expect(controller.contains("tunnelProtocol.providerBundleIdentifier = TunnelProviderIdentity.splitTunnelBundleIdentifier"))
        #expect(controller.contains("tunnelProtocol.providerConfiguration = configuration.providerConfiguration"))
        #expect(controller.contains("SplitTunnelProxyPlan.nextStep(inputs)"))
    }

    // MARK: the screen

    @Test func theSplitRulesScreenOffersAppsOnMacOS15() throws {
        let view = try Self.source("network/Shared/Views/Stats/SplitRulesView.swift")
        #expect(view.contains("""
                    #if os(macOS)
                    if #available(macOS 15.0, *) {
                        SplitTunnelAppsSection()
                    }
                    #endif
        """))
        #expect(view.contains("Text(\"\(Self.newStrings[0])\")"))
        let section = try Self.source("network/Shared/Views/Stats/SplitTunnelAppsSection.swift")
        for string in Self.newStrings.dropFirst() {
            #expect(section.contains("\"\(string)\""), "\(string)")
        }
        #expect(section.contains("blockActionsStore.addAppRule(identifier: application.identifier)"))
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
                if key.contains("URnetwork") {
                    #expect(value.contains("URnetwork Split Tunnel"), "\(locale) renamed the extension")
                }
            }
        }
    }
}
