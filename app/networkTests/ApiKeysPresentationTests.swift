//
//  ApiKeysPresentationTests.swift
//  networkTests
//

import Foundation
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import URnetwork

/**
 * What Account > API keys says: a row's name (Unnamed key without one), its
 * creation date with the year and the full date and time a screen reader
 * hears, and its whole id; the list's order; the name a create sends; the
 * states in place of the list; the delete confirmation; the Account entry
 * point; and that the screen's strings come translated from the
 * localizations store. Dates are formatted in en_US and UTC.
 */
struct ApiKeysPresentationTests {

    // test-only key ids, in creation order
    private static let olderKey = "0193b1e6-5b6d-4e7f-8a9b-0c1d2e3f4a5b"
    private static let newerKey = "0193b1e7-5b6d-4e7f-8a9b-0c1d2e3f4a5c"

    // 2026-10-03 04:00:00 UTC
    private static let createTimeMillis: Int64 = 1_791_000_000_000

    private static let format = SessionTimeFormat(
        locale: Locale(identifier: "en_US"),
        timeZone: TimeZone(identifier: "UTC")!,
        calendar: Calendar(identifier: .gregorian)
    )

    // …/apple/app/networkTests/ApiKeysPresentationTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func row(
        _ key: ApiKeyItem,
        snapshot: ApiKeysSnapshot = ApiKeysSnapshot()
    ) -> ApiKeyRowPresentation {
        ApiKeyRowPresentation(key, snapshot: snapshot, format: format)
    }

    // MARK: Rows

    @Test func aRowHasItsNameCreationDateAndId() {
        let row = Self.row(ApiKeyItem(id: Self.olderKey, name: "home server", createTimeMillis: Self.createTimeMillis))
        #expect(row.id == Self.olderKey)
        #expect(row.name == "home server")
        #expect(row.created == "Created Oct 3, 2026")
        // the whole id, which the API takes
        #expect(row.idLine == "ID 0193b1e6-5b6d-4e7f-8a9b-0c1d2e3f4a5b")
        #expect(!row.deleting)
        #expect(!row.deleteFailed)
    }

    // a key can be in use for years: the year is always there
    @Test func theCreationDateAlwaysHasItsYear() {
        // 2025-10-03
        let lastYear = Date(timeIntervalSince1970: 1_759_464_000)
        #expect(Self.format.dateWithYear(lastYear) == "Oct 3, 2025")
        let thisYear = Date(timeIntervalSince1970: TimeInterval(Self.createTimeMillis) / 1000)
        #expect(Self.format.dateWithYear(thisYear) == "Oct 3, 2026")
    }

    // CreateTime is in milliseconds; a screen reader hears the full date and
    // time
    @Test func screenReadersHearTheFullCreationDateAndTime() {
        let row = Self.row(ApiKeyItem(id: Self.olderKey, name: "home server", createTimeMillis: Self.createTimeMillis))
        let createdAt = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(row.createdAccessibilityLabel == "Created \(Self.format.full(createdAt))")
        #expect(Self.format.full(createdAt).contains("October 3, 2026"))
    }

    @Test func aKeyWithoutACreationTimeHasNoDateLine() {
        let row = Self.row(ApiKeyItem(id: Self.olderKey, name: "home server", createTimeMillis: nil))
        #expect(row.created == nil)
        #expect(row.createdAccessibilityLabel == nil)
        #expect(row.idLine == "ID \(Self.olderKey)")
    }

    // a key created through the API may have no name
    @Test func aKeyWithoutANameIsAnUnnamedKey() {
        #expect(Self.row(ApiKeyItem(id: Self.olderKey, name: "")).name == "Unnamed key")
        #expect(Self.row(ApiKeyItem(id: Self.olderKey, name: " \n ")).name == "Unnamed key")
        #expect(Self.row(ApiKeyItem(id: Self.olderKey, name: " build bot ")).name == "build bot")
    }

    // names are shown as text, whole
    @Test func longNamesAreKeptWhole() {
        let name = String(repeating: "server ", count: 18).trimmingCharacters(in: .whitespaces)
        #expect(Self.row(ApiKeyItem(id: Self.olderKey, name: name)).name == name)
    }

    @Test func aDeletingRowShowsProgressAndAFailedOneSaysSo() {
        var snapshot = ApiKeysSnapshot()
        snapshot.deletes = [
            ApiKeyDeleteItem(keyId: Self.olderKey, deleting: true),
            ApiKeyDeleteItem(keyId: Self.newerKey, deleting: false, failed: true),
        ]
        let deleting = Self.row(ApiKeyItem(id: Self.olderKey, name: "home server"), snapshot: snapshot)
        #expect(deleting.deleting)
        #expect(!deleting.deleteFailed)
        let failed = Self.row(ApiKeyItem(id: Self.newerKey, name: "build bot"), snapshot: snapshot)
        #expect(!failed.deleting)
        #expect(failed.deleteFailed)
        #expect(ApiKeysFailure.delete == "Couldn't delete the API key. Try again.")
    }

    // MARK: Order

    @Test func theListIsNewestFirst() {
        let older = ApiKeyItem(id: Self.olderKey, name: "a", createTimeMillis: 1_790_000_000_000)
        let newer = ApiKeyItem(id: Self.newerKey, name: "b", createTimeMillis: 1_791_000_000_000)
        #expect(ApiKeyOrder.sorted([older, newer]) == [newer, older])
        #expect(ApiKeyOrder.sorted([newer, older]) == [newer, older])
    }

    // ids sort by creation time
    @Test func keysCreatedTogetherGoByIdNewestFirst() {
        let older = ApiKeyItem(id: Self.olderKey, name: "a", createTimeMillis: Self.createTimeMillis)
        let newer = ApiKeyItem(id: Self.newerKey, name: "b", createTimeMillis: Self.createTimeMillis)
        #expect(ApiKeyOrder.sorted([older, newer]) == [newer, older])
    }

    @Test func keysWithoutACreationTimeGoLast() {
        let timed = ApiKeyItem(id: Self.olderKey, name: "a", createTimeMillis: Self.createTimeMillis)
        let untimedOlder = ApiKeyItem(id: "0193b1e5-0000-4000-8000-000000000001", name: "b")
        let untimedNewer = ApiKeyItem(id: Self.newerKey, name: "c")
        #expect(ApiKeyOrder.sorted([untimedOlder, timed, untimedNewer]) == [timed, untimedNewer, untimedOlder])
    }

    // MARK: Names

    @Test func aCreateSendsTheTrimmedName() {
        #expect(ApiKeyName.normalized("  home server \n") == "home server")
        #expect(ApiKeyName.normalized("home  server") == "home  server")
    }

    // the app always names a key
    @Test func aBlankNameIsNoName() {
        #expect(ApiKeyName.normalized("") == nil)
        #expect(ApiKeyName.normalized(" \t\n ") == nil)
        #expect(ApiKeyName.normalized("\u{0}") == nil)
    }

    // the server refuses a NUL character
    @Test func aNameLosesItsNulCharacters() {
        #expect(ApiKeyName.normalized("home\u{0} server") == "home server")
    }

    // account_api_key.name is varchar(128), counted in Unicode scalars as
    // the server's Go counts runes
    @Test func aNameIsCutToTheServersLimit() {
        let atLimit = String(repeating: "a", count: 128)
        #expect(ApiKeyName.limited(atLimit) == atLimit)
        #expect(ApiKeyName.limited(atLimit + "b") == atLimit)
        #expect(ApiKeyName.normalized(String(repeating: "x", count: 200)) == String(repeating: "x", count: 128))
        // a cut that ends on a space is trimmed too
        #expect(ApiKeyName.normalized(String(repeating: "a", count: 127) + " b") == String(repeating: "a", count: 127))
        #expect(ApiKeyName.maxLength == 128)
    }

    // a character of several scalars is kept whole or dropped, never split
    @Test func theCutNeverSplitsACharacter() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(family.unicodeScalars.count == 5)
        let prefix = String(repeating: "a", count: 125)
        #expect(ApiKeyName.limited(prefix + family) == prefix)
        let fits = String(repeating: "a", count: 123)
        #expect(ApiKeyName.limited(fits + family + "b") == fits + family)
        // e and a combining acute: two scalars, one character
        let accent = "e\u{301}"
        #expect(ApiKeyName.limited(String(repeating: "a", count: 127) + accent) == String(repeating: "a", count: 127))
        #expect(ApiKeyName.limited(String(repeating: "a", count: 127) + accent).unicodeScalars.count <= 128)
    }

    // MARK: States

    @Test func neverLoadedShowsProgress() {
        var snapshot = ApiKeysSnapshot()
        #expect(snapshot.content == .loading)
        snapshot.loading = true
        #expect(snapshot.content == .loading)
        #expect(!snapshot.refreshing)
    }

    @Test func aFailedFirstLoadOffersRetry() {
        var snapshot = ApiKeysSnapshot()
        snapshot.loadFailed = true
        #expect(snapshot.content == .loadFailed)
        #expect(!snapshot.refreshFailed)
        #expect(ApiKeysFailure.load == "Couldn't load your API keys. Try again.")
    }

    @Test func loadedWithNoKeysIsEmpty() {
        var snapshot = ApiKeysSnapshot()
        snapshot.loaded = true
        #expect(snapshot.content == .empty)
    }

    @Test func aRefreshKeepsTheList() {
        var snapshot = ApiKeysSnapshot()
        snapshot.loaded = true
        snapshot.keys = [ApiKeyItem(id: Self.olderKey, name: "home server")]
        #expect(snapshot.content == .list)
        snapshot.loading = true
        #expect(snapshot.refreshing)
        #expect(snapshot.content == .list)
        snapshot.loading = false
        snapshot.loadFailed = true
        #expect(snapshot.refreshFailed)
        #expect(snapshot.content == .list)
    }

    @Test func onlyTheNameFormClosesFreely() {
        #expect(ApiKeyCreateStep.naming(failed: false).closesFreely)
        #expect(ApiKeyCreateStep.naming(failed: true).closesFreely)
        #expect(!ApiKeyCreateStep.creating.closesFreely)
        #expect(!ApiKeyCreateStep.created(ApiKeyCreatedItem(id: Self.olderKey, name: "a", apiKey: "urn_TESTONLY")).closesFreely)
        #expect(ApiKeysFailure.create == "Couldn't create the API key. Try again.")
    }

    @Test func theConfirmationNamesTheKey() {
        let named = ApiKeyDeleteConfirmation(keyId: Self.olderKey, name: "home server")
        #expect(named.title == "Delete this API key?")
        #expect(named.message == "\"home server\" will stop working right away, and anything using it will lose access.")
        let unnamed = ApiKeyDeleteConfirmation(keyId: Self.olderKey, name: ApiKeyLabels.name(ApiKeyItem(id: Self.olderKey)))
        #expect(unnamed.message == "\"Unnamed key\" will stop working right away, and anything using it will lose access.")
    }

    @Test func theScreenLinksTheApiDocumentation() {
        #expect(ApiKeysLinks.docs.absoluteString == "https://ur.io/docs/api")
    }

    // MARK: Entry point

    // the Account row takes the row's icon tint, at the size of the other
    // Account icons
    @Test func theKeyGlyphIsATemplateAsset() throws {
        #if canImport(UIKit)
        let accountIconSize = try #require(UIImage(named: "ur.symbols.user.circle")).size
        let image = try #require(UIImage(named: "ur.symbols.api.key"))
        #expect(image.renderingMode == .alwaysTemplate)
        #expect(image.size == accountIconSize)
        #endif
    }

    // iOS and macOS share the Account list: API keys right after Sessions,
    // opening the screen on the account api
    @Test func theAccountListOpensApiKeysAfterSessions() throws {
        let root = try Self.source("network/Main/Account/AccountRootView.swift")
        let sessions = try #require(root.range(of: "navigate(.sessions)"))
        let apiKeys = try #require(root.range(of: "navigate(.apiKeys)"))
        let settings = try #require(root.range(of: "navigate(.settings)"))
        #expect(sessions.upperBound < apiKeys.lowerBound)
        #expect(apiKeys.upperBound < settings.lowerBound)
        #expect(root.contains("iconPath: \"ur.symbols.api.key\""))

        let stack = try Self.source("network/Main/Account/AccountNavStackView.swift")
        #expect(stack.contains("case .apiKeys:"))
        #expect(stack.contains("ApiKeysView(api: api)"))
    }

    // MARK: The key

    // the key reaches the pasteboard only through SensitivePasteboard, and
    // nothing in the screen stores, logs or selects it
    @Test func theKeyIsNeverStoredLoggedOrCopiedPlainly() throws {
        var sources: [String: String] = [:]
        for file in ["ApiKeysView.swift", "ApiKeysStore.swift", "ApiKeysPresentation.swift"] {
            sources[file] = try Self.source("network/Main/Account/ApiKeys/\(file)")
        }
        let view = try #require(sources["ApiKeysView.swift"])
        #expect(view.contains("SensitivePasteboard.copy(apiKey)"))
        for (file, text) in sources {
            for forbidden in [
                "UIPasteboard", "NSPasteboard", "UserDefaults", "@AppStorage", "@SceneStorage",
                "Keychain", "SecItem", "FileManager", ".write(", "print(", "NSLog", "os_log",
                "Logger(", "glog", "textSelection(.enabled)",
            ] {
                #expect(!text.contains(forbidden), "\(file) has \(forbidden)")
            }
        }
    }

    // MARK: Strings

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    /// the screen's own entries (api_keys_* in the localizations store)
    private static let screenStrings = [
        "API keys",
        "API keys let your own tools and scripts use your URnetwork account through the API. Anyone with a key has full access to your account until you delete it.",
        "How to use API keys",
        "You don't have any API keys.",
        "Create API key",
        "Key name",
        "For example, home server",
        "Your new API key",
        "Copy this key now. It won't be shown again, and anyone who has it can use your account.",
        "Copy key",
        "Created %@",
        "Delete this API key?",
        "\"%@\" will stop working right away, and anything using it will lose access.",
        "Couldn't load your API keys. Try again.",
        "Couldn't create the API key. Try again.",
        "Couldn't delete the API key. Try again.",
        "Unnamed key",
    ]

    /// the existing entries the screen reads (one catalog entry per English
    /// text)
    private static let sharedStrings = ["Delete", "Copied", "ID %@", "Cancel", "Done", "Retry", "Refresh"]

    @Test func everyStringIsTranslatedInEveryLocale() throws {
        let strings = try Self.catalogStrings()
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.count == 27)

        for text in Self.screenStrings + Self.sharedStrings {
            let entry = try #require(strings[text] as? [String: Any], "the catalog has no \(text)")
            #expect(entry["extractionState"] as? String != "stale", "\(text)")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(text)")
            var missing: [String] = []
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    missing.append(locale)
                    continue
                }
                // a sentence reads in the locale's language, never in English
                if locale != "en" && text.count > 40 {
                    #expect(value != text, "\(locale) is English: \(text)")
                }
            }
            #expect(missing.isEmpty, "\(text) is not translated: \(missing)")
        }
    }
}
