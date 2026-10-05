//
//  VlessSettingsTests.swift
//  networkTests
//
//  The VLESS settings editor (connect issue 91): which fields the form shows,
//  the form <-> settings mapping, the message of every sdk error id, and the
//  store saving to and loading from a real network space in a private
//  directory (no Keychain, network or NetworkExtension access).
//
//  Validating, reading links and storing are the sdk's, one implementation for
//  every app; what is pinned here is the app's side of it.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

private enum VlessFixtures {

    static let id = "5783a3e7-e373-51cd-8642-c83782b807c5"

    /// a synthetic REALITY public key: 32 bytes, base64url without padding
    static let publicKey = Data(repeating: 0x24, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    /// a REALITY server over raw tcp with the vision flow, as a share link
    /// reads; the spider path is the field the form keeps but does not edit
    static let reality = VlessSettingsValues(
        enabled: true,
        name: "home",
        address: "203.0.113.20",
        port: 443,
        id: id,
        flow: VlessSettingsOptions.flowVision,
        network: VlessSettingsOptions.networkTcp,
        security: VlessSettingsOptions.securityReality,
        serverName: "www.cover.example",
        fingerprint: "chrome",
        publicKey: publicKey,
        shortId: "0123abcd",
        spiderX: "/crawl"
    )

    static let realityLink = "vless://\(id)@203.0.113.20:443?type=tcp&security=reality&flow=xtls-rprx-vision"
        + "&sni=www.cover.example&fp=chrome&pbk=\(publicKey)&sid=0123abcd&spx=%2Fcrawl#home"

    /// a tls server behind a WebSocket front
    static let tlsWebSocket = VlessSettingsValues(
        enabled: true,
        name: "cdn",
        address: "cdn.example",
        port: 8443,
        id: id,
        network: VlessSettingsOptions.networkWs,
        security: VlessSettingsOptions.securityTls,
        serverName: "front.example",
        alpn: "h2,http/1.1",
        allowInsecure: true,
        path: "/ws",
        host: "front.example"
    )

    static func strings(_ list: SdkStringList?) -> [String] {
        guard let list else {
            return []
        }
        return (0..<list.len()).map { list.get($0) }
    }
}

struct VlessSettingsTests {

    // MARK: what the form shows

    // (network, security) -> flow, server name + fingerprint, alpn + insecure,
    // public key + short id, path + host
    @Test(arguments: [
        ("tcp", "none", false, false, false, false, false),
        ("tcp", "tls", true, true, true, false, false),
        ("tcp", "reality", true, true, false, true, false),
        ("ws", "none", false, false, false, false, true),
        ("ws", "tls", false, true, true, false, true),
        ("ws", "reality", false, true, false, true, true),
        ("httpupgrade", "none", false, false, false, false, true),
        ("httpupgrade", "tls", false, true, true, false, true),
        ("httpupgrade", "reality", false, true, false, true, true),
    ])
    func theFieldsFollowTheTransportAndTheSecurity(
        _ expected: (String, String, Bool, Bool, Bool, Bool, Bool)
    ) {
        let (network, security, flow, tlsHandshake, tlsOptions, reality, http) = expected
        var form = VlessSettingsForm()
        form.network = network
        form.security = security
        #expect(form.showsFlow == flow)
        #expect(form.showsTlsHandshake == tlsHandshake)
        #expect(form.showsTlsOptions == tlsOptions)
        #expect(form.showsReality == reality)
        #expect(form.showsHttp == http)
    }

    // the sdk's empty transport and security are tcp and none, so a form of
    // such settings shows the tcp / none fields rather than every field
    @Test func emptyTransportAndSecurityReadAsTheirDefaults() {
        let form = VlessSettingsForm(VlessSettingsValues(enabled: true, address: "vless.example", port: 443, id: VlessFixtures.id))
        #expect(form.network == VlessSettingsOptions.networkTcp)
        #expect(form.security == VlessSettingsOptions.securityNone)
        #expect(!form.showsFlow)
        #expect(!form.showsTlsHandshake)
        #expect(!form.showsHttp)
    }

    // MARK: form <-> settings

    @Test func aRealityServerRoundTripsThroughTheForm() {
        let form = VlessSettingsForm(VlessFixtures.reality)
        #expect(form.port == "443")
        #expect(form.spiderX == "/crawl")
        #expect(form.settings == VlessFixtures.reality)
    }

    @Test func aTlsWebSocketServerRoundTripsThroughTheForm() {
        let form = VlessSettingsForm(VlessFixtures.tlsWebSocket)
        #expect(form.showsHttp && form.showsTlsOptions)
        #expect(form.settings == VlessFixtures.tlsWebSocket)
    }

    // Vision is valid only where the flow picker shows: a hidden flow saves
    // as none, and the form keeps it so switching back restores it
    @Test func aHiddenFlowSavesAsNone() {
        var form = VlessSettingsForm(VlessFixtures.reality)

        form.network = VlessSettingsOptions.networkWs
        #expect(!form.showsFlow)
        #expect(form.flow == VlessSettingsOptions.flowVision)
        #expect(form.settings.flow == VlessSettingsOptions.flowNone)

        form.network = VlessSettingsOptions.networkHttpUpgrade
        #expect(form.settings.flow == VlessSettingsOptions.flowNone)

        form.network = VlessSettingsOptions.networkTcp
        #expect(form.settings.flow == VlessSettingsOptions.flowVision)

        form.security = VlessSettingsOptions.securityNone
        #expect(!form.showsFlow)
        #expect(form.settings.flow == VlessSettingsOptions.flowNone)
    }

    // every other hidden field is saved as it is: the sdk ignores what does
    // not apply, and the spider path rides along for the share link
    @Test func otherHiddenFieldsAreKept() {
        var settings = VlessFixtures.reality
        settings.alpn = "h2"
        settings.allowInsecure = true
        settings.path = "/ws"
        settings.host = "front.example"
        var form = VlessSettingsForm(settings)
        form.security = VlessSettingsOptions.securityNone
        #expect(!form.showsTlsHandshake && !form.showsTlsOptions && !form.showsReality && !form.showsHttp)

        let saved = form.settings
        #expect(saved.serverName == "www.cover.example")
        #expect(saved.fingerprint == "chrome")
        #expect(saved.alpn == "h2")
        #expect(saved.allowInsecure)
        #expect(saved.publicKey == VlessFixtures.publicKey)
        #expect(saved.shortId == "0123abcd")
        #expect(saved.spiderX == "/crawl")
        #expect(saved.path == "/ws")
        #expect(saved.host == "front.example")
    }

    @Test func thePortFieldSavesTheNumberTyped() {
        #expect(vlessSettingsPort("443") == 443)
        #expect(vlessSettingsPort(" 8443 ") == 8443)
        // the sdk reports 0 and out of range ports as an invalid port
        #expect(vlessSettingsPort("") == 0)
        #expect(vlessSettingsPort("https") == 0)
        #expect(vlessSettingsPort("99999999999999999999999") == 0)
        #expect(vlessSettingsPort("70000") == 70000)
        // an unset port shows an empty field
        #expect(VlessSettingsForm(VlessSettingsValues()).port == "")
    }

    @Test func thePortFieldKeepsDigitsOnly() {
        #expect(vlessSettingsPortText("443") == "443")
        #expect(vlessSettingsPortText("4a4 3") == "443")
        #expect(vlessSettingsPortText("-1") == "1")
        #expect(vlessSettingsPortText("٤٤٣") == "")
    }

    // MARK: errors

    @Test func everySdkErrorIdHasItsOwnMessage() {
        let fallback = vlessSettingsErrorMessage(VlessSettingsErrorId.linkInvalid).key
        let messages = VlessSettingsErrorId.all.map { vlessSettingsErrorMessage($0).key }
        #expect(VlessSettingsErrorId.all.count == 12)
        #expect(Set(messages).count == VlessSettingsErrorId.all.count)
        for errorId in VlessSettingsErrorId.all where errorId != VlessSettingsErrorId.linkInvalid {
            #expect(vlessSettingsErrorMessage(errorId).key != fallback, "\(errorId)")
        }
    }

    // an id this build does not know reads as an invalid link
    @Test func anUnknownErrorIdReadsAsAnInvalidLink() {
        for errorId in ["", "vless_error_from_a_newer_sdk", "port_invalid"] {
            #expect(vlessSettingsErrorMessage(errorId).key == "This is not a valid VLESS link.")
        }
    }

    // the English text is the catalog key, so it must be the localizations
    // store's source text exactly
    @Test func theMessagesAreTheStoreEnglish() {
        let english: [String: String] = [
            "vless_error_link_invalid": "This is not a valid VLESS link.",
            "vless_error_link_unsupported": "This link uses a VLESS feature this app does not support.",
            "vless_error_address_invalid": "Enter the server address.",
            "vless_error_port_invalid": "Enter a port from 1 to 65535.",
            "vless_error_id_invalid": "Enter the user ID (a UUID).",
            "vless_error_network_unsupported": "This transport is not supported. Use TCP, WebSocket or HTTPUpgrade.",
            "vless_error_security_unsupported": "This security type is not supported. Use TLS, REALITY or none.",
            "vless_error_flow_invalid": "The Vision flow works only with the TCP transport and TLS or REALITY security.",
            "vless_error_server_name_required": "Enter the server name (SNI) for REALITY.",
            "vless_error_fingerprint_unsupported": "This TLS fingerprint is not supported.",
            "vless_error_public_key_invalid": "Enter the REALITY public key.",
            "vless_error_short_id_invalid": "The REALITY short ID must be up to 16 hexadecimal characters.",
        ]
        #expect(Set(english.keys) == Set(VlessSettingsErrorId.all))
        for (errorId, message) in english {
            #expect(vlessSettingsErrorMessage(errorId).key == message)
        }
    }

    // a translation is found only when the English matches the catalog key
    @Test(arguments: ["de", "es", "zh-Hans"])
    func theMessagesAreTranslated(_ locale: String) {
        for errorId in VlessSettingsErrorId.all {
            var message = vlessSettingsErrorMessage(errorId)
            message.locale = Locale(identifier: locale)
            let translated = String(localized: message)
            #expect(!translated.isEmpty)
            #expect(translated != message.key, "\(locale) \(errorId): \(translated)")
        }
    }

    @Test func theErrorIdsAreTheSdkIds() {
        #expect(VlessSettingsErrorId.linkInvalid == SdkVlessErrorLinkInvalid)
        #expect(VlessSettingsErrorId.linkUnsupported == SdkVlessErrorLinkUnsupported)
        #expect(VlessSettingsErrorId.addressInvalid == SdkVlessErrorAddressInvalid)
        #expect(VlessSettingsErrorId.portInvalid == SdkVlessErrorPortInvalid)
        #expect(VlessSettingsErrorId.idInvalid == SdkVlessErrorIdInvalid)
        #expect(VlessSettingsErrorId.networkUnsupported == SdkVlessErrorNetworkUnsupported)
        #expect(VlessSettingsErrorId.securityUnsupported == SdkVlessErrorSecurityUnsupported)
        #expect(VlessSettingsErrorId.flowInvalid == SdkVlessErrorFlowInvalid)
        #expect(VlessSettingsErrorId.serverNameRequired == SdkVlessErrorServerNameRequired)
        #expect(VlessSettingsErrorId.fingerprintUnsupported == SdkVlessErrorFingerprintUnsupported)
        #expect(VlessSettingsErrorId.publicKeyInvalid == SdkVlessErrorPublicKeyInvalid)
        #expect(VlessSettingsErrorId.shortIdInvalid == SdkVlessErrorShortIdInvalid)
    }

    // MARK: the sdk side

    @Test func theOptionsAreTheSdkOptionsInItsOrder() {
        #expect(VlessSettingsOptions.networks.map(\.value) == VlessFixtures.strings(SdkVlessNetworks()))
        #expect(VlessSettingsOptions.securities.map(\.value) == VlessFixtures.strings(SdkVlessSecurities()))
        #expect(VlessSettingsOptions.flows.map(\.value) == VlessFixtures.strings(SdkVlessFlows()))
        #expect(VlessSettingsOptions.fingerprints == VlessFixtures.strings(SdkVlessFingerprints()))
    }

    @Test func theOptionLabelsAreTheStoreEnglish() {
        #expect(VlessSettingsOptions.networks.map(\.label.key) == ["TCP", "WebSocket", "HTTPUpgrade"])
        #expect(VlessSettingsOptions.securities.map(\.label.key) == ["None", "TLS", "REALITY"])
        #expect(VlessSettingsOptions.flows.map(\.label.key) == ["None", "Vision"])
        // the empty fingerprint shows None, the named client hellos verbatim
        #expect(VlessSettingsOptions.fingerprintLabel("")?.key == "None")
        #expect(VlessSettingsOptions.fingerprintLabel("chrome") == nil)
    }

    @Test func theSdkSettingsCarryEveryField() throws {
        var values = VlessFixtures.reality
        values.alpn = "h2"
        values.allowInsecure = true
        values.path = "/p"
        values.host = "h.example"
        let settings = try #require(values.sdkSettings())
        #expect(settings.id_ == VlessFixtures.id)
        #expect(settings.spiderX == "/crawl")
        #expect(VlessSettingsValues(settings) == values)
    }

    // the form a space without VLESS opens on
    @Test func aNewFormStartsFromTheSdkDefaults() throws {
        let form = VlessSettingsForm(VlessSettingsValues(try #require(SdkNewVlessSettings())))
        #expect(!form.enabled)
        #expect(form.port == "443")
        #expect(form.network == VlessSettingsOptions.networkTcp)
        #expect(form.security == VlessSettingsOptions.securityReality)
        #expect(form.flow == VlessSettingsOptions.flowVision)
        #expect(form.fingerprint == "chrome")
        #expect(form.showsFlow && form.showsReality)
    }

    // whatever transport and security the user picks, the settings the form
    // saves pass the sdk's validation; the raw values with the hidden vision
    // flow are what it would refuse
    @Test func everyTransportAndSecurityTheFormOffersValidates() {
        for network in VlessSettingsOptions.networks.map(\.value) {
            for security in VlessSettingsOptions.securities.map(\.value) {
                var form = VlessSettingsForm(VlessFixtures.reality)
                form.network = network
                form.security = security
                let errorId = vlessSettingsValidationErrorId(form.settings)
                #expect(errorId == "", "\(network) / \(security): \(errorId)")
                if !form.showsFlow {
                    var unfiltered = form.settings
                    unfiltered.flow = VlessSettingsOptions.flowVision
                    #expect(vlessSettingsValidationErrorId(unfiltered) == VlessSettingsErrorId.flowInvalid)
                }
            }
        }
    }

    // MARK: strings

    // …/apple/app/networkTests/VlessSettingsTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every string the VLESS screens and their entry points show, in the
    /// localizations store's English (the catalog key).
    private static let screenStrings = [
        "VLESS",
        "Connect to URnetwork through your own VLESS server when direct connections are blocked. Your traffic to URnetwork stays encrypted end to end.",
        "Use VLESS",
        "VLESS link",
        "Paste a vless:// link to fill in the settings.",
        "Paste link",
        "Copy link",
        "VLESS link copied",
        "Name",
        "Server address",
        "Port",
        "User ID (UUID)",
        "Transport",
        "TCP",
        "WebSocket",
        "HTTPUpgrade",
        "Security",
        "None",
        "TLS",
        "REALITY",
        "Flow",
        "Vision",
        "Server name (SNI)",
        "TLS fingerprint",
        "ALPN",
        "Allow an insecure certificate",
        "Public key",
        "Short ID",
        "Path",
        "Host header",
        "Save",
        "VLESS settings saved",
        "The VPN uses the new VLESS settings the next time it connects.",
    ]

    // a literal that is not exactly the catalog key shows untranslated
    @Test func everyStringTheScreensShowIsALocalizedCatalogKey() throws {
        let data = try Data(contentsOf: Self.appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        let sources = try [
            "network/Shared/Views/VlessSettingsView.swift",
            "network/Shared/ViewModels/VlessSettingsForm.swift",
            "network/Shared/Views/NetworkServerSheet/NetworkServerSheet.swift",
            "network/Main/Account/AccountNavStackView.swift",
            "network/Main/Account/Settings/SettingsForm-iOS.swift",
            "network/Main/Account/Settings/SettingsForm-macOS.swift",
        ].map {
            try String(contentsOf: Self.appRoot.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")

        let messages = VlessSettingsErrorId.all.map { vlessSettingsErrorMessage($0).key }
        for english in Self.screenStrings + messages {
            #expect(sources.contains("\"\(english)\""), "not in the sources as written: \(english)")
            guard let entry = strings[english] as? [String: Any] else {
                Issue.record("not in the catalog: \(english)")
                continue
            }
            #expect(entry["extractionState"] as? String != "stale", "stale: \(english)")
            if entry["shouldTranslate"] as? Bool != false {
                let localizations = entry["localizations"] as? [String: Any]
                #expect(localizations?["de"] != nil, "no de translation: \(english)")
            }
        }
    }
}

// MARK: - the store

private final class NetworkSpaceValuesUpdate: NSObject, SdkNetworkSpaceUpdateProtocol {
    private let edit: (SdkNetworkSpaceValues) -> Void

    init(_ edit: @escaping (SdkNetworkSpaceValues) -> Void) {
        self.edit = edit
    }

    func update(_ values: SdkNetworkSpaceValues?) {
        if let values {
            edit(values)
        }
    }
}

@MainActor
struct VlessSettingsStoreTests {

    private func storageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VlessSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func spaceKey() throws -> SdkNetworkSpaceKey {
        try #require(SdkNewNetworkSpaceKey("vless.example", "main"))
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

    private func newFormDefaults() throws -> VlessSettingsValues {
        VlessSettingsValues(try #require(SdkNewVlessSettings()))
    }

    @Test func aSavedFormIsWhatTheNextScreenLoads() async throws {
        try await withNetworkSpace { _, space in
            let store = VlessSettingsStore()
            store.setup(space)
            #expect(store.loaded)
            // nothing stored yet: the new-form defaults, off
            let defaults = try newFormDefaults()
            #expect(store.form == VlessSettingsForm(defaults))

            store.form = VlessSettingsForm(VlessFixtures.reality)
            await store.save()
            #expect(store.saveOutcome == .saved)
            #expect(store.form == VlessSettingsForm(VlessFixtures.reality))

            let next = VlessSettingsStore()
            next.setup(space)
            #expect(next.form == VlessSettingsForm(VlessFixtures.reality))
            let stored = VlessSettingsValues(try #require(space.getVlessSettings()))
            #expect(stored == VlessFixtures.reality)
        }
    }

    // enabled settings must validate, and nothing is saved when they do not
    @Test func enabledSettingsThatDoNotValidateAreNotSaved() async throws {
        try await withNetworkSpace { _, space in
            let store = VlessSettingsStore()
            store.setup(space)
            var form = VlessSettingsForm(VlessFixtures.reality)
            form.serverName = ""
            store.form = form
            await store.save()
            #expect(store.saveOutcome == .failed(errorId: VlessSettingsErrorId.serverNameRequired))
            // the form stays as typed so it can be fixed
            #expect(store.form == form)
            let defaults = try newFormDefaults()
            let stored = VlessSettingsValues(try #require(space.getVlessSettings()))
            #expect(stored == defaults)

            // an edit clears the outcome
            store.form.serverName = "www.cover.example"
            #expect(store.saveOutcome == nil)
        }
    }

    // switching a vision server to WebSocket saves without a flow instead of
    // failing on the hidden flow
    @Test func aHiddenFlowDoesNotFailTheSave() async throws {
        try await withNetworkSpace { _, space in
            let store = VlessSettingsStore()
            store.setup(space)
            var form = VlessSettingsForm(VlessFixtures.reality)
            form.network = VlessSettingsOptions.networkWs
            store.form = form
            await store.save()
            #expect(store.saveOutcome == .saved)
            let stored = try #require(space.getVlessSettings())
            #expect(stored.network == VlessSettingsOptions.networkWs)
            #expect(stored.flow == VlessSettingsOptions.flowNone)
            #expect(stored.spiderX == "/crawl")
        }
    }

    // settings that are off are kept as typed, without validation
    @Test func settingsThatAreOffAreSavedAsTyped() async throws {
        try await withNetworkSpace { _, space in
            let store = VlessSettingsStore()
            store.setup(space)
            var form = VlessSettingsForm(VlessFixtures.reality)
            form.enabled = false
            form.publicKey = "not a key"
            store.form = form
            await store.save()
            #expect(store.saveOutcome == .saved)
            let stored = try #require(space.getVlessSettings())
            #expect(!stored.enabled)
            #expect(stored.publicKey == "not a key")
        }
    }

    @Test func theSettingsSurviveARestart() async throws {
        let directory = try storageDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let manager = try #require(SdkNewNetworkSpaceManager(directory.path))
        let space = try #require(manager.updateNetworkSpaceValues(try spaceKey(), values: SdkNetworkSpaceValues()))
        let store = VlessSettingsStore()
        store.setup(space)
        store.form = VlessSettingsForm(VlessFixtures.reality)
        await store.save()
        #expect(store.saveOutcome == .saved)
        manager.close()

        let restarted = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            restarted.close()
        }
        let restartedSpace: SdkNetworkSpace = try #require(restarted.getNetworkSpace(try spaceKey()))
        let next = VlessSettingsStore()
        next.setup(restartedSpace)
        #expect(next.form == VlessSettingsForm(VlessFixtures.reality))
    }

    // the login sheet's Apply on the active space rebuilds it from a copy of
    // its values (DeviceManager.applyNetworkSpace), so VLESS stays
    @Test func reapplyingTheSpaceKeepsItsVlessSettings() async throws {
        try await withNetworkSpace { manager, space in
            let settings = try #require(VlessFixtures.reality.sdkSettings())
            #expect(space.setVlessSettings(settings) == "")
            let updated = try #require(manager.updateNetworkSpace(try spaceKey(), callback: NetworkSpaceValuesUpdate { values in
                values.envSecret = NetworkConfig.envSecret
                values.bundled = false
                values.linkHostName = "vless.example"
                values.migrationHostName = ""
                values.apiUrl = "https://api.vless.example"
                values.platformUrl = "wss://connect.vless.example"
            }))
            #expect(updated.getApiUrl() == "https://api.vless.example")
            let stored = VlessSettingsValues(try #require(updated.getVlessSettings()))
            #expect(stored == VlessFixtures.reality)
        }
    }

    // MARK: links

    // a link replaces the whole form, enabled, spider path included, and the
    // form copies back to a link that reads the same
    @Test func aPastedLinkReplacesTheForm() throws {
        let store = VlessSettingsStore()
        store.form.name = "typed before"
        store.pasteLink(VlessFixtures.realityLink)
        #expect(store.linkErrorId == nil)
        #expect(store.link == "")
        #expect(store.form == VlessSettingsForm(VlessFixtures.reality))

        let link = try #require(store.shareLink())
        let again = try #require(SdkParseVlessLink(link)?.settings)
        #expect(VlessSettingsValues(again) == VlessFixtures.reality)
    }

    @Test func aLinkThatDoesNotReadLeavesTheFormAndSaysWhy() {
        let store = VlessSettingsStore()
        store.form = VlessSettingsForm(VlessFixtures.tlsWebSocket)

        store.pasteLink("https://vless.example")
        #expect(store.linkErrorId == VlessSettingsErrorId.linkInvalid)
        #expect(store.link == "https://vless.example")
        #expect(store.form == VlessSettingsForm(VlessFixtures.tlsWebSocket))

        store.pasteLink("vless://\(VlessFixtures.id)@vless.example:443?encryption=mlkem768x25519plus.native.0rtt.x")
        #expect(store.linkErrorId == VlessSettingsErrorId.linkUnsupported)

        // typing in the field clears the message
        store.link = "vless://"
        #expect(store.linkErrorId == nil)

        // with nothing on the clipboard the field is read as it is
        store.pasteLink(nil)
        #expect(store.linkErrorId == VlessSettingsErrorId.linkInvalid)
        #expect(store.link == "vless://")
        #expect(store.form == VlessSettingsForm(VlessFixtures.tlsWebSocket))
    }

    @Test func copyLinkIsOfferedOnlyForSettingsThatValidate() {
        let store = VlessSettingsStore()
        store.form = VlessSettingsForm(VlessFixtures.reality)
        #expect(store.validationErrorId == "")
        #expect(store.shareLink() != nil)

        store.didCopyLink()
        #expect(store.linkCopied)

        store.form.publicKey = ""
        #expect(!store.linkCopied)
        #expect(store.validationErrorId == VlessSettingsErrorId.publicKeyInvalid)
        #expect(store.shareLink() == nil)
    }
}
