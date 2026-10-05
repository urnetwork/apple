//
//  CloudProxyLinkTests.swift
//  networkTests
//
//  The app has no protocol switch, so Settings links to the cloud proxies page
//  on ur.io for WireGuard, SOCKS and HTTPS proxies. The link must be the
//  official page and carry no credential.
//

import Foundation
import Testing
@testable import URnetwork

struct CloudProxyLinkTests {

    // …/apple/app/networkTests/CloudProxyLinkTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theLinkIsTheProxiesPageOnUrIo() {
        #expect(CloudProxyLink.url.absoluteString == "https://ur.io/app/proxies")
        #expect(CloudProxyLink.url.scheme == "https")
        #expect(CloudProxyLink.url.host == "ur.io")
        #expect(CloudProxyLink.url.path == "/app/proxies")
    }

    // never a token or an auth code in the url: ur.io signs the user in itself
    @Test func theLinkCarriesNoCredential() {
        #expect(CloudProxyLink.url.query == nil)
        #expect(CloudProxyLink.url.fragment == nil)
        #expect(CloudProxyLink.url.user == nil)
        #expect(CloudProxyLink.url.password == nil)
    }

    @Test func bothSettingsFormsOpenTheLink() throws {
        for form in ["SettingsForm-iOS.swift", "SettingsForm-macOS.swift"] {
            let url = Self.appRoot.appendingPathComponent("network/Main/Account/Settings/\(form)")
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(source.contains("CloudProxyLink.url"), "\(form) does not open the proxies page")
            #expect(source.contains("Text(\"Use WireGuard / SOCKS / HTTPS proxy\")"), "\(form) has no proxies row")
        }
    }

    @Test func theRowIsLocalized() throws {
        let catalogUrl = Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogUrl)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for key in [
            "Use WireGuard / SOCKS / HTTPS proxy",
            "Opens ur.io in your browser. SOCKS and WireGuard need Pro.",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for locale in ["ar", "de", "es", "ru", "zh-Hans", "ja", "fr"] {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["value"] as? String != nil, "\(key) has no \(locale) translation")
            }
        }
    }
}
