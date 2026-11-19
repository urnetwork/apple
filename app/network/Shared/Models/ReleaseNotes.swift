//
//  ReleaseNotes.swift
//  URnetwork
//
//  The release note the app bundles (ReleaseNotes.json in its resources),
//  which tapping the version in Account > Settings opens. The file is
//  generated from the localizations store (release-notes/latest.yaml, by
//  `npm run gen`), so never edit it by hand. It carries the latest release
//  only: `en` always, and any other store locale the note was written in.
//  Kept pure, so the decoding and the choice of locale are unit tested.
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
    /// so the note reads in the language of the screen around it.
    static var appLocalization: String {
        Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
    }

    /// The note for `localization`, an app localization or a locale
    /// identifier ("pt-BR", "pt_BR", "zh-Hans"): that exact locale, else its
    /// language ("pt-BR" reads the "pt" note), else `en`. Nil only when the
    /// file has no `en`.
    func note(for localization: String) -> Note? {
        let wanted = localization.replacingOccurrences(of: "_", with: "-")
        if let note = note(exactly: wanted) {
            return note
        }
        if let language = wanted.split(separator: "-").first,
           let note = note(exactly: String(language)) {
            return note
        }
        return locales["en"]
    }

    private func note(exactly locale: String) -> Note? {
        locales.first { $0.key.caseInsensitiveCompare(locale) == .orderedSame }?.value
    }

    /// The release date in `locale`'s long style ("November 19, 2026"); nil
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
            Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: utc)
        )
    }

    /// What the sheet shows for `localization`: the note, under the running
    /// app's `version` and the release date. Nil when there is no note to
    /// show.
    func presentation(
        version: String,
        localization: String,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> ReleaseNotesPresentation? {
        guard let note = note(for: localization) else {
            return nil
        }
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = [version, formattedDate(locale: locale, calendar: calendar) ?? ""].filter { !$0.isEmpty }
        return ReleaseNotesPresentation(note: note, facts: facts)
    }
}

/// The release notes sheet's content.
struct ReleaseNotesPresentation: Equatable {
    let note: ReleaseNotes.Note
    /// The running version and the release date, each when known.
    let facts: [String]

    /// The line under the title: "2026.11.19+1066894190 · November 19, 2026".
    var subtitle: String {
        facts.joined(separator: " · ")
    }

    /// The same line read aloud, without the separator glyph.
    var subtitleAccessibilityLabel: String {
        facts.joined(separator: ", ")
    }
}
