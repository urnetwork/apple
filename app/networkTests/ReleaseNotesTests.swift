//
//  ReleaseNotesTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/// The bundled release note that the version in Account > Settings opens,
/// by the rule every app follows (localizations README.md, "Release notes"):
/// the generated file decodes and ships in the app, a missing or invalid
/// file opens nothing, the note reads in the exact store locale, else the
/// same language in another form (never across Chinese scripts), else
/// English, the line under the title is the running build's version beside
/// the note's date in the reader's medium style, and the note keeps its own
/// direction.
struct ReleaseNotesTests {

    // …/apple/app/networkTests/ReleaseNotesTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private final class TestBundleMarker {}

    private static let gregorian = Calendar(identifier: .gregorian)

    /// A running build's version, as the Settings row shows it.
    private static let buildVersion = "2026.11.19+1103049750"

    private static func decode(_ json: String) throws -> ReleaseNotes {
        try ReleaseNotes.decode(Data(json.utf8))
    }

    /// A note in each of `locales`, titled with its locale.
    private static func notes(_ locales: [String], version: String = "2026.11", date: String = "2026-11-19") -> ReleaseNotes {
        ReleaseNotes(
            version: version,
            date: date,
            locales: Dictionary(uniqueKeysWithValues: locales.map { ($0, ReleaseNotes.Note(title: $0)) })
        )
    }

    // MARK: the generated file

    @Test func theGeneratedFileDecodes() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/ReleaseNotes.json"))
        let notes = try ReleaseNotes.decode(data)
        #expect(!notes.version.isEmpty)
        #expect(notes.formattedDate(locale: Locale(identifier: "en_US"), calendar: Self.gregorian) != nil)
        let english = try #require(notes.locales["en"])
        #expect(!english.title.isEmpty)
    }

    @Test func theAppBundlesTheNote() throws {
        // the test host is the app, so its main bundle is the app's
        let notes = try #require(ReleaseNotes.loadFromBundle())
        #expect(notes.locales["en"] != nil)
        #expect(ReleaseNotes.bundled == notes)
    }

    @Test func aMissingOrInvalidFileIsNoNote() {
        #expect(ReleaseNotes.loadFromBundle(Bundle(for: TestBundleMarker.self)) == nil)
        #expect(throws: (any Error).self) { try Self.decode("") }
        #expect(throws: (any Error).self) { try Self.decode("{\"version\": \"2026.11\"") }
        // the shape is wrong: no title, an item that is not text
        #expect(throws: (any Error).self) {
            try Self.decode(#"{"version": "2026.11", "date": "2026-11-19", "locales": {"en": {"sections": []}}}"#)
        }
        #expect(throws: (any Error).self) {
            try Self.decode(#"{"version": "2026.11", "date": "2026-11-19", "locales": {"en": {"title": "What's new", "sections": [{"items": [1]}]}}}"#)
        }
    }

    // MARK: decoding

    @Test func aFullNoteDecodes() throws {
        let notes = try Self.decode(#"""
            {
              "version": "2026.12",
              "date": "2026-12-03",
              "locales": {
                "en": {
                  "title": "What's new",
                  "intro": "Faster connects.",
                  "sections": [
                    { "heading": "New", "items": ["Release notes in Account.", "A quicker map."] },
                    { "items": ["Fixes."] }
                  ]
                },
                "pt-BR": { "title": "Novidades", "sections": [] }
              }
            }
            """#)
        #expect(notes.version == "2026.12")
        #expect(notes.date == "2026-12-03")
        #expect(notes.locales["en"] == ReleaseNotes.Note(
            title: "What's new",
            intro: "Faster connects.",
            sections: [
                ReleaseNotes.Section(heading: "New", items: ["Release notes in Account.", "A quicker map."]),
                ReleaseNotes.Section(heading: nil, items: ["Fixes."]),
            ]
        ))
        #expect(notes.locales["pt-BR"] == ReleaseNotes.Note(title: "Novidades"))
    }

    @Test func aNoteWithoutSectionsHasNone() throws {
        let notes = try Self.decode(#"{"version": "2026.11", "date": "2026-11-19", "locales": {"en": {"title": "What's new"}}}"#)
        #expect(notes.locales["en"] == ReleaseNotes.Note(title: "What's new", intro: nil, sections: []))
    }

    // MARK: the language

    @Test func theNoteIsTheExactLocaleThenTheBareLanguageThenAnotherRegion() {
        let notes = Self.notes(["en", "pt", "pt-BR", "es-419", "es-MX"])
        // the exact store locale, whatever its case or separator
        #expect(notes.noteLocale(for: "pt-BR") == "pt-BR")
        #expect(notes.noteLocale(for: "pt_BR") == "pt-BR")
        #expect(notes.noteLocale(for: "PT-br") == "pt-BR")
        #expect(notes.noteLocale(for: "es-419") == "es-419")
        // else the bare language first
        #expect(notes.noteLocale(for: "pt-PT") == "pt")
        // then another region of it, the first alphabetically
        #expect(notes.noteLocale(for: "es") == "es-419")
        #expect(notes.noteLocale(for: "es-AR") == "es-419")
        // else English
        #expect(notes.noteLocale(for: "fr") == "en")
        #expect(notes.noteLocale(for: "en_GB") == "en")
        #expect(notes.noteLocale(for: "en_US@calendar=buddhist") == "en")
        #expect(notes.noteLocale(for: "") == "en")
        #expect(notes.note(for: "pt-PT")?.title == "pt")
    }

    @Test func anotherRegionStandsInWithoutTheBareLanguage() {
        #expect(Self.notes(["en", "pt-BR"]).noteLocale(for: "pt-PT") == "pt-BR")
        #expect(Self.notes(["en", "pt-BR"]).noteLocale(for: "pt") == "pt-BR")
        #expect(Self.notes(["en", "pt-PT"]).noteLocale(for: "pt-BR") == "pt-PT")
        #expect(Self.notes(["en", "pt-BR", "pt-PT"]).noteLocale(for: "pt") == "pt-BR")
        #expect(Self.notes(["en", "pt-BR", "pt-PT"]).noteLocale(for: "pt-AO") == "pt-BR")
    }

    @Test func chineseNeverCrossesScripts() {
        let both = Self.notes(["en", "zh", "zh-HK"])
        for simplified in ["zh", "zh-Hans", "zh-CN", "zh-SG", "zh-Hans-CN", "zh_Hans_CN", "zh-Hans-SG"] {
            #expect(both.noteLocale(for: simplified) == "zh", "\(simplified)")
        }
        for traditional in ["zh-Hant", "zh-HK", "zh-TW", "zh-MO", "zh-Hant-TW", "zh-Hant-HK", "zh_Hant_MO"] {
            #expect(both.noteLocale(for: traditional) == "zh-HK", "\(traditional)")
        }

        // a note in one script never stands in for the other
        let simplifiedOnly = Self.notes(["en", "zh"])
        #expect(simplifiedOnly.noteLocale(for: "zh-Hans") == "zh")
        for traditional in ["zh-Hant", "zh-HK", "zh-TW", "zh-MO"] {
            #expect(simplifiedOnly.noteLocale(for: traditional) == "en", "\(traditional)")
        }
        let traditionalOnly = Self.notes(["en", "zh-HK"])
        #expect(traditionalOnly.noteLocale(for: "zh-TW") == "zh-HK")
        for simplified in ["zh", "zh-Hans", "zh-CN", "zh-SG"] {
            #expect(traditionalOnly.noteLocale(for: simplified) == "en", "\(simplified)")
        }
    }

    @Test func withoutEnglishAnUnmatchedLocaleHasNoNote() {
        let notes = Self.notes(["de"])
        #expect(notes.noteLocale(for: "de-AT") == "de")
        #expect(notes.noteLocale(for: "fr") == nil)
        #expect(notes.note(for: "fr") == nil)
        #expect(notes.presentation(version: Self.buildVersion, localization: "fr") == nil)
    }

    // MARK: the line under the title

    @Test func theDateIsTheCalendarDayInTheReadersMediumStyle() {
        let notes = Self.notes(["en"])
        #expect(notes.formattedDate(locale: Locale(identifier: "en_US"), calendar: Self.gregorian) == "Nov 19, 2026")
        #expect(notes.formattedDate(locale: Locale(identifier: "de_DE"), calendar: Self.gregorian) == "19. Nov. 2026")
    }

    @Test func aDateThatIsNotADayIsNotShown() {
        for date in ["", "soon", "2026-11", "2026-1-9", "2026-13-01", "2026-02-31", "2026-11-19T00:00:00Z", "20261119"] {
            let notes = Self.notes(["en"], date: date)
            #expect(notes.formattedDate(locale: Locale(identifier: "en_US"), calendar: Self.gregorian) == nil, "\(date)")
        }
    }

    @Test func theLineIsTheRunningVersionBesideTheNotesDate() throws {
        // the note's own version (2026.11) is not shown: the build's is,
        // exactly as the Settings row shows it (owner 2026-11-19)
        let notes = Self.notes(["en", "de"], version: "2026.11")
        let english = try #require(notes.presentation(
            version: Self.buildVersion,
            localization: "en",
            locale: Locale(identifier: "en_US"),
            calendar: Self.gregorian
        ))
        #expect(english.noteLocale == "en")
        #expect(english.subtitle == "2026.11.19+1103049750 · Nov 19, 2026")
        #expect(english.subtitleAccessibilityLabel == "2026.11.19+1103049750, Nov 19, 2026")

        let german = try #require(notes.presentation(
            version: Self.buildVersion,
            localization: "de",
            locale: Locale(identifier: "de_DE"),
            calendar: Self.gregorian
        ))
        #expect(german.note.title == "de")
        #expect(german.subtitle == "2026.11.19+1103049750 · 19. Nov. 2026")

        // the English fallback still dates in the reader's format
        let french = try #require(notes.presentation(
            version: Self.buildVersion,
            localization: "fr",
            locale: Locale(identifier: "fr_FR"),
            calendar: Self.gregorian
        ))
        #expect(french.noteLocale == "en")
        #expect(french.subtitle == "2026.11.19+1103049750 · 19 nov. 2026")

        // the row's stand-in for a build without a version shows as the row shows it
        #expect(notes.presentation(version: "0.0.0", localization: "en", locale: Locale(identifier: "en_US"), calendar: Self.gregorian)?.subtitle == "0.0.0 · Nov 19, 2026")

        // a blank version leaves the date alone, and a date that is not a day the version
        #expect(notes.presentation(version: " ", localization: "en", locale: Locale(identifier: "en_US"), calendar: Self.gregorian)?.subtitle == "Nov 19, 2026")
        #expect(Self.notes(["en"], date: "soon").presentation(version: Self.buildVersion, localization: "en")?.subtitle == "2026.11.19+1103049750")
    }

    // MARK: the direction

    @Test func theNoteKeepsItsOwnDirection() throws {
        let arabic = try #require(Self.notes(["en", "ar"]).presentation(version: Self.buildVersion, localization: "ar"))
        #expect(arabic.noteLocale == "ar")
        #expect(arabic.isRightToLeft)
        #expect(try #require(Self.notes(["en", "he"]).presentation(version: Self.buildVersion, localization: "he")).isRightToLeft)

        // the English fallback in an Arabic app reads left to right
        let fallback = try #require(Self.notes(["en"]).presentation(version: Self.buildVersion, localization: "ar"))
        #expect(fallback.noteLocale == "en")
        #expect(!fallback.isRightToLeft)
    }
}
