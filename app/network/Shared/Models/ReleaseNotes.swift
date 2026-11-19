//
//  ReleaseNotes.swift
//  URnetwork
//
//  The release note the app bundles (ReleaseNotes.json in its resources),
//  which tapping the version in Account > Settings opens. The file is
//  generated from the localizations store (release-notes/latest.yaml, by
//  `npm run gen`), so never edit it by hand. It carries the latest release
//  only: `en` always, and any other store locale the note was written in.
//  Every app shows it by one rule (localizations README.md, "Release
//  notes"): the language, the "<version> · <date>" line and the direction
//  below. Kept pure, so the decoding and the rule are unit tested.
//

import Foundation

struct ReleaseNotes: Decodable, Equatable {

    /// The release the note describes, as people see it ("2026.11").
    let version: String
    /// The release date, YYYY-MM-DD.
    let date: String
    /// The note by store locale ("en", "pt-BR", "zh").
    let locales: [String: Note]

    struct Note: Decodable, Equatable {
        let title: String
        let intro: String?
        /// In order; there may be none.
        let sections: [Section]

        init(title: String, intro: String? = nil, sections: [Section] = []) {
            self.title = title
            self.intro = intro
            self.sections = sections
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            intro = try container.decodeIfPresent(String.self, forKey: .intro)
            sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case title, intro, sections
        }
    }

    struct Section: Decodable, Equatable {
        let heading: String?
        let items: [String]
    }

    static let bundleResourceName = "ReleaseNotes"

    /// The note in the app bundle, read once. Nil when the file is missing
    /// or invalid: the version row then opens nothing.
    static let bundled: ReleaseNotes? = loadFromBundle()

    /// Decodes the note shipped in `bundle`; nil when it is missing or
    /// unreadable.
    static func loadFromBundle(_ bundle: Bundle = .main) -> ReleaseNotes? {
        guard let url = bundle.url(forResource: bundleResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decode(data)
    }

    static func decode(_ data: Data) throws -> ReleaseNotes {
        try JSONDecoder().decode(ReleaseNotes.self, from: data)
    }

    /// The language the app's own strings show in ("pt-BR", "zh-Hans"),
    /// which the note follows.
    static var appLocalization: String {
        Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
    }

    /// The store locale of the note to show for `localization`, an app
    /// localization or a locale identifier ("pt-BR", "pt_BR", "zh-Hans"):
    /// - that exact store locale;
    /// - else the same language in another form: the bare language first
    ///   ("pt-BR" reads "pt"), then another region of it ("pt-PT" reads
    ///   "pt-BR"; the first alphabetically when there are several);
    /// - never across Chinese scripts: the store's zh is Simplified and
    ///   zh-HK Traditional, so zh-Hans, zh-CN and zh-SG read only zh, and
    ///   zh-Hant, zh-HK, zh-TW and zh-MO read only zh-HK;
    /// - else en.
    /// Nil only when the file has no `en`.
    func noteLocale(for localization: String) -> String? {
        let wanted = Self.normalized(localization)
        if let exact = storeLocale(matching: wanted) {
            return exact
        }
        let subtags = wanted.split(separator: "-").map(String.init)
        if let language = subtags.first?.lowercased() {
            if language == "zh" {
                if let chinese = storeLocale(matching: Self.chineseStoreLocale(subtags)) {
                    return chinese
                }
            } else {
                if let bare = storeLocale(matching: language) {
                    return bare
                }
                let regions = locales.keys
                    .filter { $0.split(separator: "-").first?.lowercased() == language }
                    .sorted()
                if let region = regions.first {
                    return region
                }
            }
        }
        return storeLocale(matching: "en")
    }

    /// The note to show for `localization` (noteLocale(for:)).
    func note(for localization: String) -> Note? {
        noteLocale(for: localization).flatMap { locales[$0] }
    }

    /// The file's own spelling of `locale`, matched whatever its case.
    private func storeLocale(matching locale: String) -> String? {
        locales.keys.first { $0.caseInsensitiveCompare(locale) == .orderedSame }
    }

    /// `identifier` with "-" between its subtags and without its keywords
    /// ("en_US@calendar=buddhist" is "en-US").
    private static func normalized(_ identifier: String) -> String {
        let withoutKeywords = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return withoutKeywords
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The store's Chinese for a Chinese identifier's subtags: zh-HK for the
    /// Traditional script (Hant, or no script and the region HK, TW or MO),
    /// else zh, the Simplified.
    private static func chineseStoreLocale(_ subtags: [String]) -> String {
        let rest = subtags.dropFirst().map { $0.lowercased() }
        if rest.contains("hant") {
            return "zh-HK"
        }
        if rest.contains("hans") {
            return "zh"
        }
        if rest.contains(where: { ["hk", "tw", "mo"].contains($0) }) {
            return "zh-HK"
        }
        return "zh"
    }

    /// The release date in `locale`'s medium style ("Nov 19, 2026"); nil
    /// when the date is not YYYY-MM-DD. The date is a calendar day, so it is
    /// placed and shown in UTC and reads the same day in every time zone.
    func formattedDate(locale: Locale = .current, calendar: Calendar = .current) -> String? {
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day),
              let utc = TimeZone(identifier: "UTC") else {
            return nil
        }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = utc
        guard let releaseDay = gregorian.date(from: DateComponents(year: year, month: month, day: day)),
              gregorian.component(.day, from: releaseDay) == day else {
            return nil
        }
        return releaseDay.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: utc)
        )
    }

    /// What the sheet shows for `localization`: the note, under its own
    /// version and date. Never the running build's version: a later build
    /// carries the same note, and its version beside this note's date would
    /// pair two releases. The date reads in the reader's `locale`. Nil when
    /// there is no note to show.
    func presentation(
        localization: String,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> ReleaseNotesPresentation? {
        guard let noteLocale = noteLocale(for: localization), let note = locales[noteLocale] else {
            return nil
        }
        let version = self.version.trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = [version, formattedDate(locale: locale, calendar: calendar) ?? ""].filter { !$0.isEmpty }
        return ReleaseNotesPresentation(note: note, noteLocale: noteLocale, facts: facts)
    }
}

/// The release notes sheet's content.
struct ReleaseNotesPresentation: Equatable {
    let note: ReleaseNotes.Note
    /// The store locale the note is written in ("en", "ar").
    let noteLocale: String
    /// The note's version and date, each when known.
    let facts: [String]

    /// The line under the title: "2026.11 · Nov 19, 2026".
    var subtitle: String {
        facts.joined(separator: " · ")
    }

    /// The same line read aloud, without the separator glyph.
    var subtitleAccessibilityLabel: String {
        facts.joined(separator: ", ")
    }

    /// Whether the note's language reads right to left (ar, he). The note is
    /// laid out in its own direction, so the English one reads left to right
    /// in an Arabic or Hebrew app.
    var isRightToLeft: Bool {
        Locale.Language(identifier: noteLocale).characterDirection == .rightToLeft
    }
}
