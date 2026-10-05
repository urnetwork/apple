//
//  FixedIpSubtitleCopyTests.swift
//  networkTests
//
//  Fixed IP keeps one exit for the session (connect stickyExit: no standing
//  spare and no hourly rotation), so the toggle in the connect options says
//  so in a subtitle, translated from the localizations store
//  (fixed_ip_subtitle).
//
//  Reads the view source and the generated string catalog; no device.
//

import Foundation
import Testing

struct FixedIpSubtitleCopyTests {

    private static let subtitle = "Keeps one exit for the session; changes only if that provider goes offline."

    // …/apple/app/networkTests/FixedIpSubtitleCopyTests.swift -> …/apple/app
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

    @Test func theFixedIpToggleShowsTheSubtitle() throws {
        let view = try Self.source("network/Main/Connect/ConnectActions/ConnectActions.swift")
        let toggle = try #require(view.range(of: "Toggle(isOn: $fixedIpSize) {"))
        let label = try #require(view.range(of: "Text(\"Fixed IP\")", range: toggle.upperBound..<view.endIndex))
        let subtitle = try #require(
            view.range(of: "Text(\"\(Self.subtitle)\")", range: label.upperBound..<view.endIndex),
            "the Fixed IP toggle has no subtitle"
        )
        // inside the toggle's label, before the toggle's modifiers
        let disabled = try #require(view.range(of: ".disabled(selectedWindowType == .auto)", range: label.upperBound..<view.endIndex))
        #expect(subtitle.upperBound <= disabled.lowerBound)
    }

    @Test func theSubtitleIsTranslatedInEveryLocale() throws {
        let strings = try Self.catalogStrings()
        // every locale the catalog ships a translation for
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))

        let entry = try #require(strings[Self.subtitle] as? [String: Any], "the catalog has no \(Self.subtitle)")
        #expect(entry["extractionState"] as? String != "stale")
        let localizations = try #require(entry["localizations"] as? [String: Any])

        var missing: [String] = []
        for locale in locales.sorted() {
            guard let value = Self.value(localizations, locale), !value.isEmpty else {
                missing.append(locale)
                continue
            }
            if locale != "en" {
                #expect(value != Self.subtitle, "\(locale) is English")
            }
        }
        #expect(missing.isEmpty, "not translated: \(missing)")
    }
}
