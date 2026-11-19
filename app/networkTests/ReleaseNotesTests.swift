//
//  ReleaseNotesTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/// The bundled release note that the version in Account > Settings opens:
/// the generated file decodes and ships in the app, a missing or invalid
/// file opens nothing, the note reads in the exact locale, else its
/// language, else English, and the line under the title is the running
/// version and the release date.
struct ReleaseNotesTests {

    // …/apple/app/networkTests/ReleaseNotesTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private final class TestBundleMarker {}

    private static let gregorian = Calendar(identifier: .gregorian)

    private static func decode(_ json: String) throws -> ReleaseNotes {
        try ReleaseNotes.decode(Data(json.utf8))
    }

    private static func notes(_ locales: [String: String]) -> ReleaseNotes {
        ReleaseNotes(
            version: "2026.11",
            date: "2026-11-19",
            locales: locales.mapValues { ReleaseNotes.Note(title: $0) }
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

    // MARK: the locale

    @Test func theNoteIsTheExactLocaleThenItsLanguageThenEnglish() {
        let notes = Self.notes([
            "en": "What's new", "pt": "Novidades (pt)", "pt-BR": "Novidades (pt-BR)",
            "es-419": "Novedades (es-419)", "es": "Novedades (es)", "zh": "新功能",
        ])
        // the exact locale, whatever its case or separator
        #expect(notes.note(for: "pt-BR")?.title == "Novidades (pt-BR)")
        #expect(notes.note(for: "pt_BR")?.title == "Novidades (pt-BR)")
        #expect(notes.note(for: "PT-br")?.title == "Novidades (pt-BR)")
        #expect(notes.note(for: "es-419")?.title == "Novedades (es-419)")
        // else its language: the apple localization zh-Hans is the store's zh
        #expect(notes.note(for: "pt-PT")?.title == "Novidades (pt)")
        #expect(notes.note(for: "es-AR")?.title == "Novedades (es)")
        #expect(notes.note(for: "zh-Hans")?.title == "新功能")
        #expect(notes.note(for: "zh-Hans_CN")?.title == "新功能")
        // else English
        #expect(notes.note(for: "fr")?.title == "What's new")
        #expect(notes.note(for: "en_GB")?.title == "What's new")
        #expect(notes.note(for: "")?.title == "What's new")
    }

    @Test func aRegionalNoteIsNotTheLanguages() {
        // a pt-BR note does not stand in for pt: only the language is a fallback
        let notes = Self.notes(["en": "What's new", "pt-BR": "Novidades"])
        #expect(notes.note(for: "pt-BR")?.title == "Novidades")
        #expect(notes.note(for: "pt")?.title == "What's new")
        #expect(notes.note(for: "pt-PT")?.title == "What's new")
    }

    @Test func withoutEnglishAnUnmatchedLocaleHasNoNote() {
        let notes = Self.notes(["de": "Neuigkeiten"])
        #expect(notes.note(for: "de-AT")?.title == "Neuigkeiten")
        #expect(notes.note(for: "fr") == nil)
        #expect(notes.presentation(version: "2026.11.19", localization: "fr") == nil)
    }

    // MARK: the line under the title

    @Test func theDateIsTheCalendarDayInTheReadersLanguage() {
        let notes = Self.notes(["en": "What's new"])
        #expect(notes.formattedDate(locale: Locale(identifier: "en_US"), calendar: Self.gregorian) == "November 19, 2026")
        #expect(notes.formattedDate(locale: Locale(identifier: "de_DE"), calendar: Self.gregorian) == "19. November 2026")
    }

    @Test func aDateThatIsNotADayIsNotShown() {
        for date in ["", "soon", "2026-11", "2026-1-9", "2026-13-01", "2026-02-31", "2026-11-19T00:00:00Z", "20261119"] {
            let notes = ReleaseNotes(version: "2026.11", date: date, locales: ["en": ReleaseNotes.Note(title: "What's new")])
            #expect(notes.formattedDate(locale: Locale(identifier: "en_US"), calendar: Self.gregorian) == nil, "\(date)")
        }
    }

    @Test func theSubtitleIsTheRunningVersionAndTheDate() throws {
        let notes = Self.notes(["en": "What's new", "de": "Neuigkeiten"])
        let english = try #require(notes.presentation(
            version: "2026.11.19+1066894190",
            localization: "en",
            locale: Locale(identifier: "en_US"),
            calendar: Self.gregorian
        ))
        #expect(english.note.title == "What's new")
        #expect(english.subtitle == "2026.11.19+1066894190 · November 19, 2026")
        #expect(english.subtitleAccessibilityLabel == "2026.11.19+1066894190, November 19, 2026")

        let german = try #require(notes.presentation(
            version: "2026.11.19+1066894190",
            localization: "de",
            locale: Locale(identifier: "de_DE"),
            calendar: Self.gregorian
        ))
        #expect(german.note.title == "Neuigkeiten")
        #expect(german.subtitle == "2026.11.19+1066894190 · 19. November 2026")

        // a build without a version shows the date alone
        let unversioned = try #require(notes.presentation(
            version: " ",
            localization: "en",
            locale: Locale(identifier: "en_US"),
            calendar: Self.gregorian
        ))
        #expect(unversioned.subtitle == "November 19, 2026")

        // a date that is not a day leaves the version alone
        let undated = ReleaseNotes(version: "2026.11", date: "soon", locales: ["en": ReleaseNotes.Note(title: "What's new")])
        #expect(undated.presentation(version: "2026.11.19", localization: "en")?.subtitle == "2026.11.19")
    }
}
