//
//  ControlDohSettingsTests.swift
//  networkTests
//
//  The bootstrap DNS-over-HTTPS servers field (P216): how the multiline field
//  reads as the list the sdk is given and shows the list it stores, the
//  message of every sdk error id, the import line, and the store saving to and
//  loading from a real network space in a private directory (no Keychain,
//  network or NetworkExtension access).
//
//  Checking urls, the presets and storing are the sdk's, one implementation
//  for every app; what is pinned here is the app's side of it.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

private enum ControlDohFixtures {

    /// `RegionalControlDohUrls("cn")`, v4 first: AliDNS, then DNSPod
    static let chinaPreset = [
        "https://223.5.5.5/dns-query",
        "https://223.6.6.6/dns-query",
        "https://1.12.12.12/dns-query",
        "https://120.53.53.53/dns-query",
    ]

    static func stringList(_ strings: [String]) -> SdkStringList? {
        let list = SdkNewStringList()
        for string in strings {
            list?.add(string)
        }
        return list
    }
}

struct ControlDohSettingsTests {

    // MARK: the field

    // windows (\r\n), old mac (\r) and unix (\n) line endings read the same
    @Test func aLineEndsAtANewlineOrACarriageReturn() {
        #expect(controlDohUrls("https://223.5.5.5/dns-query\r\nhttps://223.6.6.6/dns-query\rhttps://1.12.12.12/dns-query\n") == [
            "https://223.5.5.5/dns-query",
            "https://223.6.6.6/dns-query",
            "https://1.12.12.12/dns-query",
        ])
    }

    @Test func blankLinesAndPaddingAreNotServers() {
        #expect(controlDohUrls("  https://223.5.5.5/dns-query \n\n\t\r\n   \nhttps://[2400:3200::1]/dns-query\t") == [
            "https://223.5.5.5/dns-query",
            "https://[2400:3200::1]/dns-query",
        ])
        #expect(controlDohUrls("") == [])
        #expect(controlDohUrls(" \r\n\t\n") == [])
    }

    @Test func aCommaDoesNotSeparateServers() {
        #expect(controlDohUrls("https://223.5.5.5/dns-query,https://223.6.6.6/dns-query") == [
            "https://223.5.5.5/dns-query,https://223.6.6.6/dns-query",
        ])
        #expect(controlDohUrls("https://223.5.5.5/dns-query, https://223.6.6.6/dns-query") == [
            "https://223.5.5.5/dns-query, https://223.6.6.6/dns-query",
        ])
    }

    // the order typed is the order tried, and the sdk drops the repeat
    @Test func theLinesKeepTheirOrderAndRepeatsForTheSdk() {
        #expect(controlDohUrls("https://1.12.12.12/dns-query\nhttps://223.5.5.5/dns-query\nhttps://1.12.12.12/dns-query") == [
            "https://1.12.12.12/dns-query",
            "https://223.5.5.5/dns-query",
            "https://1.12.12.12/dns-query",
        ])
    }

    @Test func thePresetFillsTheFieldOneServerPerLine() {
        #expect(ControlDohPreset.china == "cn")
        #expect(controlDohChinaPreset() == ControlDohFixtures.chinaPreset)
        let text = controlDohText(controlDohChinaPreset())
        #expect(text == "https://223.5.5.5/dns-query\nhttps://223.6.6.6/dns-query\nhttps://1.12.12.12/dns-query\nhttps://120.53.53.53/dns-query")
        #expect(controlDohUrls(text) == ControlDohFixtures.chinaPreset)
        // no servers is an empty field, the default servers alone
        #expect(controlDohText([]) == "")
    }

    // the sdk's check of each line: the first that fails is the one shown
    @Test func theFirstLineThatFailsIsShown() {
        #expect(controlDohValidationErrorId(ControlDohFixtures.chinaPreset) == "")
        #expect(controlDohValidationErrorId([]) == "")
        #expect(controlDohValidationErrorId([
            "https://223.5.5.5/dns-query",
            "http://223.6.6.6/dns-query",
            "https://dns.alidns.com/dns-query",
        ]) == ControlDohErrorId.httpsRequired)
        #expect(controlDohValidationErrorId(["https://dns.alidns.com/dns-query"]) == ControlDohErrorId.ipRequired)
        #expect(controlDohValidationErrorId(["223.5.5.5"]) != "")
    }

    // MARK: errors

    @Test func everySdkErrorIdHasItsOwnMessage() {
        let fallback = controlDohErrorMessage(ControlDohErrorId.urlInvalid).key
        let messages = ControlDohErrorId.all.map { controlDohErrorMessage($0).key }
        #expect(ControlDohErrorId.all.count == 4)
        #expect(Set(messages).count == ControlDohErrorId.all.count)
        for errorId in ControlDohErrorId.all where errorId != ControlDohErrorId.urlInvalid {
            #expect(controlDohErrorMessage(errorId).key != fallback, "\(errorId)")
        }
    }

    // an id this build does not know reads as an invalid url
    @Test func anUnknownErrorIdReadsAsAnInvalidUrl() {
        for errorId in ["", "control_doh_error_from_a_newer_sdk", "ip_required", "vless_error_link_invalid"] {
            #expect(controlDohErrorMessage(errorId).key == "Enter a full URL, such as https://223.5.5.5/dns-query.")
        }
    }

    // the English text is the catalog key, so it must be the localizations
    // store's source text exactly
    @Test func theMessagesAreTheStoreEnglish() {
        let english: [String: String] = [
            "control_doh_error_url_invalid": "Enter a full URL, such as https://223.5.5.5/dns-query.",
            "control_doh_error_https_required": "The URL must start with https://.",
            "control_doh_error_ip_required": "Use an IP address, not a host name, such as https://223.5.5.5/dns-query.",
            "control_doh_error_too_many": "Too many servers. Remove some and save again.",
        ]
        #expect(Set(english.keys) == Set(ControlDohErrorId.all))
        for (errorId, message) in english {
            #expect(controlDohErrorMessage(errorId).key == message)
        }
    }

    // a translation is found only when the English matches the catalog key
    @Test(arguments: ["de", "es", "zh-Hans"])
    func theMessagesAreTranslated(_ locale: String) {
        for errorId in ControlDohErrorId.all {
            var message = controlDohErrorMessage(errorId)
            message.locale = Locale(identifier: locale)
            let translated = String(localized: message)
            #expect(!translated.isEmpty)
            #expect(translated != message.key, "\(locale) \(errorId): \(translated)")
        }
    }

    @Test func theErrorIdsAreTheSdkIds() {
        #expect(ControlDohErrorId.urlInvalid == SdkControlDohErrorUrlInvalid)
        #expect(ControlDohErrorId.httpsRequired == SdkControlDohErrorHttpsRequired)
        #expect(ControlDohErrorId.ipRequired == SdkControlDohErrorIpRequired)
        #expect(ControlDohErrorId.tooMany == SdkControlDohErrorTooMany)
    }

    // MARK: the import line

    // the decision reads the servers of the sdk result's settings block, and
    // the line lists them as the settings would set them
    @Test func aDecodeResultWithServersNamesThem() {
        let result = SdkExtenderShareDecodeResult()
        result.ok = true
        result.networkHost = "bringyour.com"
        result.count = 5
        result.hasSettings = true
        result.settingsHost = "extender.bringyour.com"
        result.controlDohUrls = ControlDohFixtures.stringList(["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"])

        let decision = extenderImportDecision(result)
        #expect(decision == .ready(
            count: 5,
            hasSettings: true,
            settingsHost: "extender.bringyour.com",
            requiresSettings: false,
            controlDohUrls: ["https://223.5.5.5/dns-query", "https://1.12.12.12/dns-query"]
        ))
        #expect(extenderImportControlDohServers(decision) == "https://223.5.5.5/dns-query, https://1.12.12.12/dns-query")
        // taking them is taking the settings, which is confirmed first
        #expect(extenderImportNeedsConfirmation(decision, useSettings: true))
        #expect(!extenderImportNeedsConfirmation(decision, useSettings: false))
    }

    @Test func aPayloadThatSetsNoServersHasNoLine() {
        // settings that name none leave this space's servers alone
        let settingsOnly = extenderImportDecision(
            ok: true, error: "", networkHost: "bringyour.com", foreignHost: false,
            count: 3, hasSettings: true, settingsHost: "extender.bringyour.com"
        )
        #expect(extenderImportControlDohServers(settingsOnly) == nil)

        // servers ride only in a settings block
        let noSettings = extenderImportDecision(
            ok: true, error: "", networkHost: "bringyour.com", foreignHost: false,
            count: 3, hasSettings: false, settingsHost: "",
            controlDohUrls: ["https://223.5.5.5/dns-query"]
        )
        #expect(noSettings == .ready(count: 3, hasSettings: false, settingsHost: "", requiresSettings: false))
        #expect(extenderImportControlDohServers(noSettings) == nil)

        #expect(extenderImportControlDohServers(.invalid) == nil)
        #expect(extenderImportControlDohServers(.foreignWithoutSettings(networkHost: "other.example.com")) == nil)

        // a decode result without servers reads as none
        let result = SdkExtenderShareDecodeResult()
        result.ok = true
        result.hasSettings = true
        result.settingsHost = "extender.bringyour.com"
        #expect(extenderImportControlDohServers(extenderImportDecision(result)) == nil)
    }

    // MARK: strings

    // …/apple/app/networkTests/ControlDohSettingsTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every string the field and its entry points show, in the localizations
    /// store's English (the catalog key).
    private static let screenStrings = [
        "Bootstrap DNS-over-HTTPS servers",
        "URnetwork looks up the names of its own servers over DNS-over-HTTPS. If the built-in servers are blocked on your network, add servers that work there. URnetwork tries them first, and they can see these lookups.",
        "One URL per line, starting with https:// and an IP address, such as https://223.5.5.5/dns-query.",
        "Use China resolvers",
        "Fills in the AliDNS and DNSPod servers, which are reachable in mainland China.",
        "Use built-in servers only",
        "Save",
        "Bootstrap DNS-over-HTTPS servers saved",
        "The VPN uses the new bootstrap servers the next time it connects.",
    ]

    /// The import line, whose servers the Swift literal interpolates: `%@` in
    /// the catalog key.
    private static let importLine = "This code also sets bootstrap DNS-over-HTTPS servers. They will see URnetwork's server lookups: "

    // a literal that is not exactly the catalog key shows untranslated
    @Test func everyStringTheFieldShowsIsALocalizedCatalogKey() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let sources = try [
            "network/Shared/Views/ControlDohSettingsView.swift",
            "network/Shared/ViewModels/ControlDohSettingsForm.swift",
            "network/Shared/Views/NetworkServerSheet/NetworkServerSheet.swift",
            "network/Main/Account/ImportExtendersView.swift",
        ].map {
            try String(contentsOf: Self.appRoot.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        let messages = ControlDohErrorId.all.map { controlDohErrorMessage($0).key }
        var keys: [String] = []
        for english in Self.screenStrings + messages {
            #expect(sources.contains("\"\(english)\""), "not in the sources as written: \(english)")
            keys.append(english)
        }
        #expect(sources.contains("\"\(Self.importLine)\\(servers)\""), "the import line is not in the sources as written")
        keys.append(Self.importLine + "%@")

        for key in keys {
            guard let entry = strings[key] as? [String: Any] else {
                Issue.record("not in the catalog: \(key)")
                continue
            }
            #expect(entry["extractionState"] as? String != "stale", "stale: \(key)")
            let localizations = entry["localizations"] as? [String: Any]
            #expect(localizations?["de"] != nil, "no de translation: \(key)")
        }
    }
}

// MARK: - the store

@MainActor
struct ControlDohSettingsStoreTests {

    private func storageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ControlDohSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func spaceKey() throws -> SdkNetworkSpaceKey {
        try #require(SdkNewNetworkSpaceKey("controldoh.example", "main"))
    }

    /// A space under its own manager in a private directory, as the login
    /// screen has one before sign-in.
    private func withNetworkSpace(
        _ body: (_ manager: SdkNetworkSpaceManager, _ space: SdkNetworkSpace) async throws -> Void
    ) async throws {
        let directory = try storageDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let manager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            manager.close()
        }
        let space = try #require(manager.updateNetworkSpaceValues(try spaceKey(), values: SdkNetworkSpaceValues()))
        try await body(manager, space)
    }

    // the China preset saves, reads back as the field shows it, and is what the
    // next screen loads. The save applies in place: the space the screen holds
    // takes the servers itself and is still the manager's space, rather than
    // being replaced by a rebuilt one.
    @Test func theChinaPresetSavesInPlaceAndReadsBack() async throws {
        try await withNetworkSpace { manager, space in
            let store = ControlDohSettingsStore()
            store.setup(space)
            #expect(store.loaded)
            // nothing stored yet: the default servers alone, an empty field
            #expect(store.text == "")

            store.useChinaPreset()
            #expect(store.text == controlDohText(ControlDohFixtures.chinaPreset))
            #expect(store.errorId == nil)
            // the preset fills the field only; nothing is saved yet
            #expect(controlDohStrings(space.getControlDohUrls()) == [])

            await store.save()
            #expect(store.saveOutcome == .saved)
            #expect(store.text == controlDohText(ControlDohFixtures.chinaPreset))

            #expect(controlDohStrings(space.getControlDohUrls()) == ControlDohFixtures.chinaPreset)
            #expect(controlDohStrings(space.getControlDohUrlsIpv4()) == ControlDohFixtures.chinaPreset)
            #expect(controlDohStrings(space.getControlDohUrlsIpv6()) == [])
            let managerSpace = try #require(manager.getNetworkSpace(try spaceKey()))
            #expect(controlDohStrings(managerSpace.getControlDohUrls()) == ControlDohFixtures.chinaPreset)
            #expect(space.getApi() != nil)

            let next = ControlDohSettingsStore()
            next.setup(managerSpace)
            #expect(next.text == controlDohText(ControlDohFixtures.chinaPreset))
        }
    }

    // a host name is refused and nothing is saved; the field keeps the text as
    // typed so it can be fixed, and an edit clears the outcome
    @Test func aHostNameIsRefusedAndNothingIsSaved() async throws {
        try await withNetworkSpace { _, space in
            #expect(space.setControlDohUrls(ControlDohFixtures.stringList(["https://120.53.53.53/dns-query"])) == "")

            let store = ControlDohSettingsStore()
            store.setup(space)
            #expect(store.text == "https://120.53.53.53/dns-query")

            let typed = "https://223.5.5.5/dns-query\nhttps://dns.alidns.com/dns-query"
            store.text = typed
            // the live check already names the line
            #expect(store.errorId == ControlDohErrorId.ipRequired)

            await store.save()
            #expect(store.saveOutcome == .failed(errorId: ControlDohErrorId.ipRequired))
            #expect(store.errorId == ControlDohErrorId.ipRequired)
            #expect(store.text == typed)
            #expect(controlDohStrings(space.getControlDohUrls()) == ["https://120.53.53.53/dns-query"])

            store.text = "https://223.5.5.5/dns-query"
            #expect(store.saveOutcome == nil)
            #expect(store.errorId == nil)
        }
    }

    // the field shows what the space stores: normalized, without repeats or
    // blank lines, v4 first
    @Test func aSavedFieldShowsTheStoredList() async throws {
        try await withNetworkSpace { _, space in
            let store = ControlDohSettingsStore()
            store.setup(space)
            store.text = "\r\n https://[2400:3200::1]/dns-query \r\nhttps://223.5.5.5/dns-query\n\nhttps://223.5.5.5/dns-query\n"
            await store.save()
            #expect(store.saveOutcome == .saved)
            #expect(store.text == "https://223.5.5.5/dns-query\nhttps://[2400:3200::1]/dns-query")
            #expect(controlDohStrings(space.getControlDohUrlsIpv6()) == ["https://[2400:3200::1]/dns-query"])
        }
    }

    // "Use built-in servers only" clears the field and saves at once
    @Test func theResetSavesTheEmptyList() async throws {
        try await withNetworkSpace { _, space in
            #expect(space.setControlDohUrls(ControlDohFixtures.stringList(ControlDohFixtures.chinaPreset)) == "")

            let store = ControlDohSettingsStore()
            store.setup(space)
            #expect(store.text == controlDohText(ControlDohFixtures.chinaPreset))

            await store.reset()
            #expect(store.saveOutcome == .saved)
            #expect(store.text == "")
            #expect(controlDohStrings(space.getControlDohUrls()) == [])
        }
    }

    // an import with settings replaces the space's servers under the open
    // screen, which reads them again
    @Test func aReloadShowsServersSetMeanwhile() async throws {
        try await withNetworkSpace { _, space in
            let store = ControlDohSettingsStore()
            store.setup(space)
            #expect(store.text == "")

            #expect(space.setControlDohUrls(ControlDohFixtures.stringList(["https://1.12.12.12/dns-query"])) == "")
            // the same space again keeps the field as it is
            store.setup(space)
            #expect(store.text == "")

            store.reload()
            #expect(store.text == "https://1.12.12.12/dns-query")
        }
    }

    // without a space there is nothing to edit or save
    @Test func noSpaceIsNotLoaded() async {
        let store = ControlDohSettingsStore()
        store.setup(nil)
        #expect(!store.loaded)
        store.useChinaPreset()
        await store.save()
        #expect(store.saveOutcome == nil)
    }
}
