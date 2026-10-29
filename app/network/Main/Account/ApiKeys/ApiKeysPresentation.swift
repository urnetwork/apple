//
//  ApiKeysPresentation.swift
//  URnetwork
//
//  What Account > API keys says, as plain values: each row's name, creation
//  date and id, with the full date and time a screen reader speaks instead,
//  the order of the list, the name a create sends, the delete confirmation
//  and the failures. Pure, so the labels, dates and order are tested without
//  a view. Every string is from the string catalog; key names are shown as
//  text.
//

import Foundation

/// The API documentation the screen links to.
enum ApiKeysLinks {
    static let docs = URL(string: "https://ur.io/docs/api")!
}

/// The labels of a key.
enum ApiKeyLabels {

    /// The name, trimmed, or Unnamed key for a key created without one
    /// (through the API).
    static func name(_ key: ApiKeyItem) -> String {
        let name = key.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Unnamed key") : name
    }
}

/// Names as the server takes them.
enum ApiKeyName {

    /// account_api_key.name is varchar(128), which the server counts as Go
    /// counts runes: Unicode scalars.
    static let maxLength = 128

    /// The name a create sends: without NUL characters (the server refuses
    /// them), trimmed, and within the limit; nil when nothing is left, since
    /// the app always names a key.
    static func normalized(_ name: String) -> String? {
        let withoutNul = name.replacingOccurrences(of: "\u{0}", with: "")
        // trimmed again after the cut, which can end on a space
        let normalized = limited(withoutNul.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// The name field's text, cut to the limit between characters, so a
    /// character made of several scalars is kept whole or dropped.
    static func limited(_ text: String) -> String {
        guard maxLength < text.unicodeScalars.count else {
            return text
        }
        var scalarCount = 0
        var limited = ""
        for character in text {
            let characterScalarCount = character.unicodeScalars.count
            if maxLength < scalarCount + characterScalarCount {
                break
            }
            scalarCount += characterScalarCount
            limited.append(character)
        }
        return limited
    }
}

/// The list's order: newest first. Keys created in the same millisecond, and
/// keys without a creation time (listed last), go by id, newest first: ids
/// sort by creation time.
enum ApiKeyOrder {

    static func sorted(_ keys: [ApiKeyItem]) -> [ApiKeyItem] {
        keys.sorted { a, b in
            switch (a.createTimeMillis, b.createTimeMillis) {
            case let (aTime?, bTime?) where aTime != bTime:
                return aTime > bTime
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return a.id > b.id
            }
        }
    }
}

/// One row of the list.
struct ApiKeyRowPresentation: Equatable, Identifiable {
    /// the key's id, which Delete sends
    let id: String
    /// line 1: the name, or Unnamed key
    let name: String
    /// line 2: "Created Oct 29, 2026"; nil when the server sent no creation
    /// time
    let created: String?
    let createdAccessibilityLabel: String?
    /// line 3: the whole id, for use with the API: "ID 0193b1e6-…"
    let idLine: String
    /// the delete is in flight: progress, and no Delete
    let deleting: Bool
    /// the last delete failed
    let deleteFailed: Bool

    /// `format` is the Sessions screen's locale, time zone and calendar.
    init(_ key: ApiKeyItem, snapshot: ApiKeysSnapshot, format: SessionTimeFormat) {
        let delete = snapshot.delete(for: key.id)

        id = key.id
        name = ApiKeyLabels.name(key)
        if let createTimeMillis = key.createTimeMillis {
            let createdAt = Date(timeIntervalSince1970: TimeInterval(createTimeMillis) / 1000)
            created = String(format: String(localized: "Created %@"), format.dateWithYear(createdAt))
            createdAccessibilityLabel = String(format: String(localized: "Created %@"), format.full(createdAt))
        } else {
            created = nil
            createdAccessibilityLabel = nil
        }
        idLine = String(format: String(localized: "ID %@"), key.id)
        deleting = delete?.deleting ?? false
        deleteFailed = !deleting && (delete?.failed ?? false)
    }
}

extension SessionTimeFormat {

    /// A date with its year, such as "Oct 29, 2026": a key can be in use
    /// for years.
    func dateWithYear(_ date: Date) -> String {
        var calendar = self.calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }
}

extension ApiKeysSnapshot {

    /// The rows, newest first.
    func rows(format: SessionTimeFormat) -> [ApiKeyRowPresentation] {
        keys.map { ApiKeyRowPresentation($0, snapshot: self, format: format) }
    }
}

/// The failures, each in place of what failed.
enum ApiKeysFailure {

    /// in place of the list after a failed first load, and over the list
    /// after a failed refresh, each with Retry
    static var load: String {
        String(localized: "Couldn't load your API keys. Try again.")
    }

    /// on the name form; the name stays for another try
    static var create: String {
        String(localized: "Couldn't create the API key. Try again.")
    }

    /// on the key's row, which offers Delete again
    static var delete: String {
        String(localized: "Couldn't delete the API key. Try again.")
    }
}

extension ApiKeyCreateStep {

    /// the name form, which Cancel and a swipe may close; the sheet stays
    /// while a create is in flight and while it shows the new key
    var closesFreely: Bool {
        if case .naming = self {
            return true
        }
        return false
    }
}

extension ApiKeyDeleteConfirmation {

    var title: String {
        String(localized: "Delete this API key?")
    }

    var message: String {
        String(format: String(localized: "\"%@\" will stop working right away, and anything using it will lose access."), name)
    }
}
