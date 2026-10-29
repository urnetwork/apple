//
//  ProtocolCatalogTests.swift
//  networkTests
//
//  Apple looks a string up by its English text, and an interpolated lookup
//  by its format: a String placeholder is %@, an integer one %lld. A lookup
//  whose format is not the store's source misses the catalog and shows its
//  English in every language, which no English test can see
//  (CatalogLookupTests checks only plain literals). So every interpolated
//  lookup of the Protocol leaderboard and the Earnings tile is checked
//  here: its format is in the catalog, and the same interpolation reads
//  German from the German strings the catalog builds.
//

import Foundation
import Testing
@testable import URnetwork

struct ProtocolCatalogTests {

    // …/apple/app/networkTests/ProtocolCatalogTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The formats ProtocolText interpolates, as the store's sources.
    private static let formats = [
        "Rankings last updated %@.",
        "of %lld ranked networks",
        "%@ above the Top 200 line",
        "%@ below the Top 200 line",
        "up %lld since the last update",
        "down %lld since the last update",
        "Distinct IP prefixes: %lld. Shared with other networks: %lld.",
        "If you claimed alone today: %@.",
        "Projected rank over 90 days, now %lld",
        "Top 200 line · score %@",
        "Top 200 line, score %@",
        "UID %lld",
        "#%lld of %lld claimed",
        "Epoch %lld",
        "projected · %@",
    ]

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    @Test func everyInterpolatedFormatIsInTheCatalog() throws {
        let strings = try Self.catalogStrings()
        let missing = Self.formats.filter { strings[$0] == nil }
        #expect(missing.isEmpty, "not in Localizable.xcstrings: \(missing)")
    }

    /// The app's German strings, as the catalog builds them.
    private static func german() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "de", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func theInterpolationsReadTheirTranslations() throws {
        let de = try Self.german()
        let count = 3
        let uid: Int64 = 81
        let epoch: Int64 = 16
        let text = "12%"
        // each line interpolates the types ProtocolText does; an English
        // result means the lookup missed the catalog
        let lookups: [(String, String)] = [
            (String(localized: "Rankings last updated \(text).", bundle: de), "Rankings last updated 12%."),
            (String(localized: "of \(count) ranked networks", bundle: de), "of 3 ranked networks"),
            (String(localized: "\(text) above the Top 200 line", bundle: de), "12% above the Top 200 line"),
            (String(localized: "\(text) below the Top 200 line", bundle: de), "12% below the Top 200 line"),
            (String(localized: "up \(count) since the last update", bundle: de), "up 3 since the last update"),
            (String(localized: "down \(count) since the last update", bundle: de), "down 3 since the last update"),
            (String(localized: "Distinct IP prefixes: \(count). Shared with other networks: \(count).", bundle: de), "Distinct IP prefixes: 3. Shared with other networks: 3."),
            (String(localized: "If you claimed alone today: \(text).", bundle: de), "If you claimed alone today: 12%."),
            (String(localized: "Projected rank over 90 days, now \(count)", bundle: de), "Projected rank over 90 days, now 3"),
            (String(localized: "Top 200 line · score \(text)", bundle: de), "Top 200 line · score 12%"),
            (String(localized: "Top 200 line, score \(text)", bundle: de), "Top 200 line, score 12%"),
            (String(localized: "UID \(uid)", bundle: de), "UID 81"),
            (String(localized: "#\(count) of \(count) claimed", bundle: de), "#3 of 3 claimed"),
            (String(localized: "Epoch \(epoch)", bundle: de), "Epoch 16"),
            (String(localized: "projected · \(text)", bundle: de), "projected · 12%"),
        ]
        for (german, english) in lookups {
            // "UID 81" may read the same in German; its catalog entry is
            // checked above
            if english == "UID 81" {
                continue
            }
            #expect(german != english, "read English: \(english)")
        }
    }
}
