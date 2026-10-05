//
//  AppShortcutsCatalogTests.swift
//  networkTests
//
//  Siri runs the connect and disconnect App Shortcuts (Shortcuts.swift) when
//  a spoken request matches one of their phrases in the language Siri speaks,
//  and it reads the phrases' translations only from the AppShortcuts string
//  table. Until the localizations store generated that table the phrases were
//  English in every language, so a Siri set to German or Japanese had nothing
//  to match. The table is generated from the store's `table: AppShortcuts`
//  keys as one <language>.lproj/AppShortcuts.strings per language Siri speaks
//  (its String Catalog form needs an iOS 17 deployment target); a phrase added
//  to Shortcuts.swift without a store key, or a language a key lacks, is a
//  phrase Siri only knows in English.
//
//  Reads Shortcuts.swift and the generated tables; no device.
//

import Foundation
import Testing

struct AppShortcutsCatalogTests {

    // …/apple/app/networkTests/AppShortcutsCatalogTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The app's languages that Siri speaks (the store's SIRI_LOCALES, with zh
    /// as zh-Hans): every phrase reads in each of them.
    private static let siriLocales = [
        "ar", "de", "en", "es", "es-419", "es-MX", "fr", "he", "it", "ja", "ko",
        "nl", "pt", "pt-BR", "ru", "sv", "th", "zh-Hans", "zh-HK",
    ]

    @Test func theScannerReadsThePhrases() {
        let source = #"""
            AppShortcut(
                intent: ConnectIntent(),
                phrases: [
                    "Start \(.applicationName)",
                    // "Commented \(.applicationName)",
                    "Connect to \(.applicationName) VPN"
                ],
                shortTitle: "Connect URnetwork VPN",
                systemImageName: "pin"
            )
            /* AppShortcut(intent: OtherIntent(), phrases: ["Block \(.applicationName)"]) */
            AppShortcut(intent: DisconnectIntent(), phrases: ["Stop \(.applicationName)"], shortTitle: "Stop")
            """#
        #expect(AppShortcutsPhraseScanner.phrases(source: source) == [
            "Start ${applicationName}",
            "Connect to ${applicationName} VPN",
            "Stop ${applicationName}",
        ])
    }

    @Test func everyPhraseReadsInEveryLanguageSiriSpeaks() throws {
        let source = try String(
            contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Shortcuts/Shortcuts.swift"),
            encoding: .utf8
        )
        let phrases = AppShortcutsPhraseScanner.phrases(source: source)
        #expect(phrases.count >= 14, "the scan saw \(phrases.count) phrases; Shortcuts.swift has fourteen")

        let resources = Self.appRoot.appendingPathComponent("network/Shared/Resources")
        var misses: [String] = []
        // a table for a language Siri does not speak is one no one keeps
        let tableLocales = try FileManager.default.contentsOfDirectory(atPath: resources.path)
            .filter { $0.hasSuffix(".lproj") }
            .filter { FileManager.default.fileExists(atPath: resources.appendingPathComponent("\($0)/AppShortcuts.strings").path) }
            .map { String($0.dropLast(".lproj".count)) }
        for locale in tableLocales.sorted() where !Self.siriLocales.contains(locale) {
            misses.append("\(locale).lproj/AppShortcuts.strings is for a language Siri does not speak")
        }
        for locale in Self.siriLocales {
            let file = "\(locale).lproj/AppShortcuts.strings"
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(file)) else {
                misses.append("\(file) is missing: every phrase is English only in \(locale)")
                continue
            }
            let table = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                "\(file) does not parse"
            )
            // what a phrase says (case and spacing aside) -> the phrase
            var phraseBySaid: [String: String] = [:]
            for phrase in phrases {
                guard let value = table[phrase] else {
                    misses.append("\(phrase.debugDescription) is not in \(file)")
                    continue
                }
                // the build rejects a phrase without the app's name
                if value.components(separatedBy: AppShortcutsPhraseScanner.applicationName).count != 2 {
                    misses.append("\(phrase.debugDescription) in \(locale), \(value.debugDescription), does not carry the app's name once")
                }
                // two phrases that read alike leave Siri two intents to choose from
                let said = value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if let other = phraseBySaid[said] {
                    misses.append("\(phrase.debugDescription) and \(other.debugDescription) both read \(value.debugDescription) in \(locale)")
                }
                phraseBySaid[said] = phrase
            }
            // the table carries no phrase the app no longer has
            for key in table.keys.sorted() where !phrases.contains(key) {
                misses.append("\(key.debugDescription) is in \(file) but no longer in Shortcuts.swift")
            }
        }
        #expect(
            misses.isEmpty,
            "give each phrase a localizations store key (table: AppShortcuts, its source the phrase as Xcode extracts it) in every language Siri speaks, and regenerate:\n\(misses.joined(separator: "\n"))"
        )
    }
}

/// Reads the phrases of the App Shortcuts in a Swift source: the string
/// literals of each `phrases: [ … ]` array, comments skipped, with
/// \(.applicationName) written as Xcode extracts it into the catalog key.
private enum AppShortcutsPhraseScanner {

    static let applicationName = "${applicationName}"

    static func phrases(source: String) -> [String] {
        let scalars = Array(source.unicodeScalars)
        var phrases: [String] = []
        var index = 0
        func at(_ position: Int) -> Unicode.Scalar? {
            position < scalars.count ? scalars[position] : nil
        }
        func starts(with text: String, at position: Int) -> Bool {
            for (offset, scalar) in text.unicodeScalars.enumerated() where at(position + offset) != scalar {
                return false
            }
            return true
        }
        // the literal whose opening quote is at `index`; leaves `index` past it
        func readLiteral() -> String {
            var value = String.UnicodeScalarView()
            index += 1
            while let scalar = at(index), scalar != "\"", scalar != "\n" {
                if scalar == "\\" && starts(with: "\\(.applicationName)", at: index) {
                    value.append(contentsOf: applicationName.unicodeScalars)
                    index += "\\(.applicationName)".unicodeScalars.count
                } else if scalar == "\\", let escaped = at(index + 1) {
                    value.append(escaped)
                    index += 2
                } else {
                    value.append(scalar)
                    index += 1
                }
            }
            index += 1
            return String(value)
        }
        // inside a phrases array: its bracket depth, 0 outside one
        var depth = 0
        while let scalar = at(index) {
            if scalar == "/" && at(index + 1) == "/" {
                while let next = at(index), next != "\n" {
                    index += 1
                }
            } else if scalar == "/" && at(index + 1) == "*" {
                while index < scalars.count && !(at(index) == "*" && at(index + 1) == "/") {
                    index += 1
                }
                index += 2
            } else if scalar == "\"" {
                let literal = readLiteral()
                if depth > 0 {
                    phrases.append(literal)
                }
            } else if depth == 0 && starts(with: "phrases:", at: index)
                && !(index > 0 && (scalars[index - 1] == "_" || CharacterSet.alphanumerics.contains(scalars[index - 1])))
            {
                index += "phrases:".unicodeScalars.count
                while let next = at(index), CharacterSet.whitespacesAndNewlines.contains(next) {
                    index += 1
                }
                if at(index) == "[" {
                    depth = 1
                    index += 1
                }
            } else {
                if depth > 0 && scalar == "[" {
                    depth += 1
                } else if depth > 0 && scalar == "]" {
                    depth -= 1
                }
                index += 1
            }
        }
        return phrases
    }
}
