//
//  CatalogLookupTests.swift
//  networkTests
//
//  SwiftUI looks a literal title up in the string catalog by its text, so a
//  Text("…") whose text the catalog lacks shows its English in every language
//  and nothing reports it. The catalog is generated from the localizations
//  store (the keys tagged apple, keyed by their `source`), so a literal added
//  to a view without a store key, or a key whose source no longer matches the
//  literal, reads in English everywhere: the Software update section, the
//  split rule modes, the throughput widget's "peak" and some sixty more did.
//
//  Reads every Swift source under network/ and the generated string catalog;
//  no device. The scan sees the plain literal first argument of the SwiftUI
//  initializers and modifiers that take a LocalizedStringKey, and
//  String(localized:). An interpolated literal ("\(n) flows") is keyed by its
//  format, and a custom view's LocalizedStringKey parameter by its type, so
//  neither is checked here.
//

import Foundation
import Testing

struct CatalogLookupTests {

    // …/apple/app/networkTests/CatalogLookupTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Literals the scan sees that no person reads as a translated title, each
    /// with the reason.
    private static let notLookedUp: [String: String] = [
        "rejected": "the marker of a DEBUG hardware UI-testing view",
        "👑": "an emoji, with nothing to translate",
    ]

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    @Test func theScannerReadsTheLiteralLookups() {
        let source = #"""
            Text("Plain title")
            Text("Count: \(count) of \(total)")
            Text(verbatim: "Verbatim")
            Button("Save") { save() }
            Toggle("Fast DNS", isOn: $fast)
                .navigationTitle("Settings")
                .help("Shown on hover")
            help("Not a modifier")
            Text("A" + suffix)
            // Text("Line comment")
            /* Text("Block /* nested */ comment") */
            Text("Escaped \"quote\" \u{2014} done")
            String(localized: "Localized string", comment: "A note")
            let embedded = "Text(\"In a string\")"
            Text("""
                Multi-line
                """)
            Text(#"Raw"#)
            Section("Header") { Text(title) }
            #Preview {
                Text("Preview only")
            }
            Text("After the preview")
            """#
        let lookups = CatalogLiteralScanner.lookups(file: "synthetic.swift", source: source)
        #expect(lookups.map { "\($0.line) \($0.function) \($0.key)" } == [
            "1 Text Plain title",
            "4 Button Save",
            "5 Toggle Fast DNS",
            "6 navigationTitle Settings",
            "7 help Shown on hover",
            "12 Text Escaped \"quote\" \u{2014} done",
            "13 String Localized string",
            "19 Section Header",
            "23 Text After the preview",
        ])
    }

    @Test func everyLiteralLookupIsInTheCatalog() throws {
        let strings = try Self.catalogStrings()
        let network = Self.appRoot.appendingPathComponent("network")
        let files = try #require(FileManager.default.enumerator(at: network, includingPropertiesForKeys: nil))
        // #filePath and the enumerator may name the root through different
        // links (/tmp and /private/tmp)
        let rootPath = Self.appRoot.resolvingSymlinksInPath().path + "/"
        var lookups: [CatalogLiteralLookup] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let path = url.resolvingSymlinksInPath().path
            let file = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
            lookups += CatalogLiteralScanner.lookups(file: file, source: source)
        }
        #expect(lookups.count > 600, "the scan saw \(lookups.count) literal lookups; the app has about eight hundred")

        var misses: [String] = []
        for lookup in lookups where Self.notLookedUp[lookup.key] == nil {
            let call = "\(lookup.file):\(lookup.line): \(lookup.function)(\(lookup.key.debugDescription))"
            guard let entry = strings[lookup.key] as? [String: Any] else {
                misses.append("\(call) is not in the catalog")
                continue
            }
            if entry["extractionState"] as? String == "stale" {
                misses.append("\(call) is a stale entry")
            }
        }
        #expect(
            misses.isEmpty,
            "give each a localizations store key tagged apple whose source is the literal, and regenerate:\n\(misses.joined(separator: "\n"))"
        )

        // the exceptions shrink with the code
        let keys = Set(lookups.map(\.key))
        for (literal, reason) in Self.notLookedUp {
            #expect(keys.contains(literal), "\(literal) (\(reason)) is no longer looked up: drop it from notLookedUp")
        }
    }
}

/// One literal a source hands to SwiftUI as a LocalizedStringKey: the
/// initializer or modifier that takes it, the literal's text (the catalog
/// key), and the line of the call.
private struct CatalogLiteralLookup: Equatable {
    let file: String
    let line: Int
    let function: String
    let key: String
}

/// Reads Swift sources for the string literals SwiftUI looks up in the string
/// catalog: the first argument of the initializers and modifiers below when it
/// is a plain literal (no interpolation, not multi-line, not raw), and
/// String(localized:). Comments and #Preview bodies are skipped.
private enum CatalogLiteralScanner {

    /// The initializers whose literal first argument is a LocalizedStringKey.
    static let initializers: Set<String> = [
        "Text", "Button", "Label", "Toggle", "Section", "TextField", "SecureField", "Picker",
        "LabeledContent", "Link", "Menu", "NavigationLink", "LocalizedStringKey", "LocalizedStringResource",
    ]

    /// The modifiers whose literal first argument is a LocalizedStringKey.
    static let modifiers: Set<String> = [
        "navigationTitle", "help", "accessibilityLabel", "accessibilityHint", "alert", "confirmationDialog",
    ]

    /// A word (an identifier, or # and a directive's name), a string literal
    /// (its text, or nil when it is interpolated, multi-line or raw) or one
    /// punctuation character, with the line it starts on.
    enum Token: Equatable {
        case word(String, Int)
        case literal(String?, Int)
        case punct(Character, Int)
    }

    /// The source as tokens, comments dropped.
    static func tokens(_ source: String) -> [Token] {
        let scalars = Array(source.unicodeScalars)
        var tokens: [Token] = []
        var index = 0
        var line = 1
        func at(_ position: Int) -> Unicode.Scalar? {
            position < scalars.count ? scalars[position] : nil
        }
        func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
        }
        // the literal whose opening quote is at `index`, raw with `hashes` #s;
        // leaves `index` past its closing delimiter
        func readLiteral(hashes: Int) -> String? {
            let multiline = at(index) == "\"" && at(index + 1) == "\"" && at(index + 2) == "\""
            index += multiline ? 3 : 1
            var value = String.UnicodeScalarView()
            var plain = hashes == 0 && !multiline
            func closes(_ position: Int) -> Bool {
                let quotes = multiline ? 3 : 1
                for offset in 0..<quotes where at(position + offset) != "\"" {
                    return false
                }
                for offset in 0..<hashes where at(position + quotes + offset) != "#" {
                    return false
                }
                return true
            }
            while let scalar = at(index) {
                if closes(index) {
                    index += (multiline ? 3 : 1) + hashes
                    return plain ? String(value) : nil
                }
                if scalar == "\n" {
                    if !multiline {
                        // an unterminated literal ends at the line
                        return nil
                    }
                    line += 1
                }
                var escaped = scalar == "\\"
                for offset in 0..<hashes where at(index + 1 + offset) != "#" {
                    escaped = false
                }
                if !escaped {
                    value.append(scalar)
                    index += 1
                    continue
                }
                index += 1 + hashes
                guard let escape = at(index) else {
                    return nil
                }
                index += 1
                switch escape {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "0": value.append("\0")
                case "u":
                    // \u{XXXX}
                    var digits = ""
                    if at(index) == "{" {
                        index += 1
                        while let digit = at(index), digit != "}" {
                            digits.unicodeScalars.append(digit)
                            index += 1
                        }
                        index += 1
                    }
                    if let code = UInt32(digits, radix: 16), let decoded = Unicode.Scalar(code) {
                        value.append(decoded)
                    }
                case "(":
                    // an interpolation, to its closing parenthesis
                    plain = false
                    var depth = 1
                    while depth > 0, let inner = at(index) {
                        if inner == "\"" {
                            _ = readLiteral(hashes: 0)
                            continue
                        }
                        if inner == "(" {
                            depth += 1
                        } else if inner == ")" {
                            depth -= 1
                        } else if inner == "\n" {
                            line += 1
                        }
                        index += 1
                    }
                default:
                    value.append(escape)
                }
            }
            return nil
        }
        while let scalar = at(index) {
            if scalar == "\n" {
                line += 1
                index += 1
                continue
            }
            if CharacterSet.whitespaces.contains(scalar) {
                index += 1
                continue
            }
            if scalar == "/" && at(index + 1) == "/" {
                while let next = at(index), next != "\n" {
                    index += 1
                }
                continue
            }
            if scalar == "/" && at(index + 1) == "*" {
                // block comments nest
                var depth = 0
                repeat {
                    if at(index) == "/" && at(index + 1) == "*" {
                        depth += 1
                        index += 2
                    } else if at(index) == "*" && at(index + 1) == "/" {
                        depth -= 1
                        index += 2
                    } else {
                        if at(index) == "\n" {
                            line += 1
                        }
                        index += 1
                    }
                } while depth > 0 && index < scalars.count
                continue
            }
            if scalar == "\"" || scalar == "#" {
                var hashes = 0
                while at(index + hashes) == "#" {
                    hashes += 1
                }
                if at(index + hashes) == "\"" {
                    let startLine = line
                    index += hashes
                    tokens.append(.literal(readLiteral(hashes: hashes), startLine))
                    continue
                }
            }
            if scalar == "#" || isWordScalar(scalar) {
                var word = String.UnicodeScalarView()
                word.append(scalar)
                index += 1
                while let next = at(index), isWordScalar(next) {
                    word.append(next)
                    index += 1
                }
                tokens.append(.word(String(word), line))
                continue
            }
            tokens.append(.punct(Character(scalar), line))
            index += 1
        }
        return tokens
    }

    /// The literal lookups of one source.
    static func lookups(file: String, source: String) -> [CatalogLiteralLookup] {
        let tokens = tokens(source)
        func isPunct(_ position: Int, _ character: Character) -> Bool {
            guard position >= 0, position < tokens.count, case let .punct(found, _) = tokens[position] else {
                return false
            }
            return found == character
        }
        // the #Preview bodies, from their opening brace to its match
        var skipped = [Bool](repeating: false, count: tokens.count)
        for position in tokens.indices {
            guard case .word("#Preview", _) = tokens[position] else {
                continue
            }
            var open = position + 1
            while open < tokens.count && !isPunct(open, "{") {
                open += 1
            }
            var depth = 0
            var close = open
            while close < tokens.count {
                if isPunct(close, "{") {
                    depth += 1
                } else if isPunct(close, "}") {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                }
                close += 1
            }
            for inside in position..<min(close + 1, tokens.count) {
                skipped[inside] = true
            }
        }
        var lookups: [CatalogLiteralLookup] = []
        for position in tokens.indices where !skipped[position] {
            guard case let .word(name, line) = tokens[position], isPunct(position + 1, "(") else {
                continue
            }
            let member = isPunct(position - 1, ".")
            var argument = position + 2
            if name == "String" && !member {
                guard argument + 1 < tokens.count, case .word("localized", _) = tokens[argument],
                    isPunct(argument + 1, ":")
                else {
                    continue
                }
                argument += 2
            } else if !(initializers.contains(name) && !member) && !(modifiers.contains(name) && member) {
                continue
            }
            // a whole literal: what follows it ends the argument
            guard argument < tokens.count, case let .literal(key?, _) = tokens[argument],
                isPunct(argument + 1, ",") || isPunct(argument + 1, ")")
            else {
                continue
            }
            lookups.append(CatalogLiteralLookup(file: file, line: line, function: name, key: key))
        }
        return lookups
    }
}
