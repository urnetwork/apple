//
//  SeekerStringsLocalizedTests.swift
//  networkTests
//
//  The Earnings screen's Seeker row said "The Seeker multiplier applies to
//  points only." The multiplier also doubles the free daily data and the
//  referral data (server pro.yml seeker.data_multiplier), so the row now
//  carries the benefit line the other apps show, translated from the
//  localizations store.
//
//  Reads the view source and the generated string catalog; no device.
//

import Foundation
import Testing

struct SeekerStringsLocalizedTests {

    private static let benefit = "Doubles your points, free daily data and referral data."
    private static let pointsOnly = "The Seeker multiplier applies to points only."

    // …/apple/app/networkTests/SeekerStringsLocalizedTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    private static func value(_ localizations: [String: Any], _ locale: String) -> String? {
        let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    @Test func theSeekerRowSaysWhatTheMultiplierDoubles() throws {
        let view = try Self.source("network/Shared/Views/AccountPointsBreakdown.swift")
        #expect(view.contains("Text(\"\(Self.benefit)\")"))
        #expect(!view.contains(Self.pointsOnly))
    }

    @Test func theBenefitLineIsTranslatedInEveryLocale() throws {
        let strings = try Self.catalogStrings()
        // every locale the catalog ships a translation for
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))

        let entry = try #require(strings[Self.benefit] as? [String: Any], "the catalog has no \(Self.benefit)")
        #expect(entry["extractionState"] as? String != "stale")
        let localizations = try #require(entry["localizations"] as? [String: Any])

        var missing: [String] = []
        for locale in locales.sorted() {
            guard let value = Self.value(localizations, locale), !value.isEmpty else {
                missing.append(locale)
                continue
            }
            if locale != "en" {
                #expect(value != Self.benefit, "\(locale) is English")
            }
        }
        #expect(missing.isEmpty, "not translated: \(missing)")
    }

    @Test func thePointsOnlyLineIsRetired() throws {
        let strings = try Self.catalogStrings()
        if let entry = strings[Self.pointsOnly] as? [String: Any] {
            #expect(entry["extractionState"] as? String == "stale")
        }
    }
}
