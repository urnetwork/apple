//
//  ExtenderResetWiringTests.swift
//  networkTests
//
//  The Extenders screen's side of "Reset extenders" (EXTENDER.md E7), which
//  no unit test can tap: the button beside Share and Import only asks, the
//  confirmation says what goes and offers a destructive "Reset extenders" and
//  Cancel, only its action resets, and the screen then says so. These read
//  the screen's source (ExtenderResetStoreTests drives the store it binds
//  to); every string it shows must be the localizations store's English,
//  translated in every locale the catalog ships.
//

import Foundation
import Testing
@testable import URnetwork

struct ExtenderResetWiringTests {

    private static let button = "Reset extenders"
    private static let confirmation = "This removes the extenders you added and clears everything learned about extenders, which are then discovered again from scratch."
    private static let done = "Extenders reset"

    // …/apple/app/networkTests/ExtenderResetWiringTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func view() throws -> String {
        try String(
            contentsOf: appRoot.appendingPathComponent("network/Main/Account/ExtendersView.swift"),
            encoding: .utf8
        )
    }

    /// The source from the first `start` on, up to the first `end` after it.
    private static func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start), "no \(start)")
        let endRange = try #require(
            source.range(of: end, range: startRange.upperBound..<source.endIndex),
            "no \(end) after \(start)"
        )
        return source[startRange.lowerBound..<endRange.upperBound]
    }

    // the button follows Share and Import in their group, is off until the
    // settings load and while a reset runs, and a press only asks
    @Test func theButtonBesideShareAndImportOnlyAsks() throws {
        let view = try Self.view()
        let group = try Self.section(view, from: "text: \"Share extenders\"", to: "Divider()")
        let importButton = try #require(group.range(of: "text: \"Import extenders\""))
        let resetButton = try #require(group.range(of: "text: \"\(Self.button)\""))
        #expect(importButton.upperBound <= resetButton.lowerBound)

        let button = try Self.section(view, from: "text: \"\(Self.button)\"", to: ")\n")
        #expect(button.contains("action: { store.requestResetExtenders() }"))
        #expect(button.contains("style: .outlineSecondary"))
        #expect(button.contains("enabled: store.loaded,"))
        #expect(button.contains("isProcessing: store.resettingExtenders"))
    }

    // the confirmation is the store's, titled with the action, and only its
    // destructive action resets
    @Test func theConfirmationAloneResets() throws {
        let view = try Self.view()
        let dialog = try Self.section(view, from: ".confirmationDialog(", to: "Text(\"\(Self.confirmation)\")")
        let title = dialog.dropFirst(".confirmationDialog(".count).drop(while: { $0.isWhitespace })
        #expect(title.hasPrefix("\"\(Self.button)\","))
        #expect(dialog.contains("isPresented: $store.confirmingResetExtenders"))
        #expect(dialog.contains("titleVisibility: .visible"))
        let destructive = try Self.section(String(dialog), from: "Button(\"\(Self.button)\", role: .destructive) {", to: "}")
        #expect(destructive.contains("await resetExtenders()"))
        #expect(dialog.contains("Button(\"Cancel\", role: .cancel) {}"))
        #expect(dialog.contains("} message: {"))

        // the screen resets in one place, the action's, and says so when the
        // reset ran
        #expect(view.components(separatedBy: "store.resetExtenders()").count == 2)
        #expect(view.components(separatedBy: "await resetExtenders()").count == 2)
        let reset = try Self.section(view, from: "private func resetExtenders() async {", to: "\n    }\n")
        #expect(reset.contains("""
                if await store.resetExtenders() {
                    snackbarManager.showSnackbar(message: String(localized: "\(Self.done)"))
                }
        """))
    }

    // a save while the reset runs would write the values from before it back
    @Test func saveWaitsForTheReset() throws {
        let view = try Self.view()
        let save = try Self.section(view, from: "text: \"Save\"", to: ")\n")
        #expect(save.contains("enabled: store.loaded && !store.resettingExtenders"))
    }

    // a literal that is not exactly the catalog key shows untranslated
    @Test func theStringsAreTranslatedInEveryLocale() throws {
        let view = try Self.view()
        for string in [Self.button, Self.confirmation, Self.done] {
            #expect(view.contains("\"\(string)\""), "not in the screen as written: \(string)")
        }

        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        // every locale the catalog ships a translation for
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("de"))

        for key in [Self.button, Self.confirmation, Self.done] {
            guard let entry = strings[key] as? [String: Any] else {
                Issue.record("not in the catalog: \(key)")
                continue
            }
            #expect(entry["extractionState"] as? String != "stale", "stale: \(key)")
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(locale) has no \(key)")
            }
        }
    }
}
