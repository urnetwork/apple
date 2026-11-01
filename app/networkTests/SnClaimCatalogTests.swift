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
}
