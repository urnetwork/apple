//
//  SnClaimCatalogTests.swift
//  networkTests
//
//  The string catalog carries the v1 claim words Earnings reads (support
//  inbox 8126): "No payout published" for an epoch the vault finalized
//  without a payout root, and "Claimable epochs: %lld" under the unclaimed
//  total, each translated in every locale the catalog ships. The count's
//  old wording, "Across %lld finalized epochs", is gone: it counted
//  claimable epochs. SnClaimTextTests checks the lookups themselves.
//
//  It carries the capture the flag claim flow's words from the localizations
//  store too (sn/CAPTURETHEFLAG.md §10), each in every locale with its
//  placeholder: the pools' names, a pool row's unavailable and under-floor
//  states, Claim both and the won-slot lines.
//
//  Reads the generated catalog; no device.
//

import Foundation
import Testing

struct SnClaimCatalogTests {

    // …/apple/app/networkTests/SnClaimCatalogTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func theCatalogCarriesBothStringsInEveryLocaleAndNotTheFinalizedCount() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))
        #expect(strings["Across %lld finalized epochs"] == nil)
        for key in ["No payout published", "Claimable epochs: %lld"] {
            let entry = try #require(strings[key] as? [String: Any], "the catalog has no \(key)")
            #expect(entry["extractionState"] as? String != "stale", "\(key) is stale")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            var missing: [String] = []
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    missing.append(locale)
                    continue
                }
                if key.contains("%lld") {
                    #expect(value.contains("%lld"), "\(key) in \(locale) lost %lld")
                }
            }
            #expect(missing.isEmpty, "\(key) not translated: \(missing)")
        }
    }

    /// the capture the flag claim flow's words, keyed by their English as the
    /// store's `source` gives them
    private static let captureTheFlagStrings = [
        "Capture the flag",
        "Provider pool",
        "Below the claim minimum",
        "Unavailable right now",
        "Claim both",
        "You won one of the %@ provider slots",
        "You won one of the %@ extender slots",
    ]

    @Test func theCatalogCarriesTheCaptureTheFlagStringsInEveryLocale() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))
        for key in Self.captureTheFlagStrings {
            let entry = try #require(strings[key] as? [String: Any], "the catalog has no \(key)")
            #expect(entry["extractionState"] as? String != "stale", "\(key) is stale")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            var missing: [String] = []
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    missing.append(locale)
                    continue
                }
                // the country is inserted as is, wherever the language puts it
                if key.contains("%@") {
                    #expect(value.contains("%@"), "\(key) in \(locale) lost %@")
                }
            }
            #expect(missing.isEmpty, "\(key) not translated: \(missing)")
        }
    }
}
