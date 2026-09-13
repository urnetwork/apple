//
//  ExtenderShareImportTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The share and import screens' decisions (EXTENDER.md K7): what a decoded
 * payload lets the user do, when the settings must be taken with it, and when
 * a confirmation stands between the user and a replaced trust anchor.
 *
 * Encoding, decoding and applying are the sdk's, one implementation for every
 * app; what is pinned here is the app's reading of the result.
 */
struct ExtenderShareImportTests {

    // MARK: settings fields

    // K6: the hosts box is one hostname or ip per line, and what it stores is
    // exactly the lines a user can see
    @Test func hostsAreTheNonBlankLinesInOrder() {
        #expect(extenderSettingsHosts("a.example.com\n192.0.2.1") == ["a.example.com", "192.0.2.1"])
        #expect(extenderSettingsHosts("  a.example.com  \n\n\n  \n192.0.2.1\n") == ["a.example.com", "192.0.2.1"])
        #expect(extenderSettingsHosts("") == [])
        #expect(extenderSettingsHosts("   \n  ") == [])
    }

    @Test func hostsRoundTripThroughTheField() {
        let hosts = ["a.example.com", "2001:db8::1"]
        #expect(extenderSettingsHosts(extenderSettingsHostsText(hosts)) == hosts)
    }

    @Test func aPrivateExtenderIsEmptyUntilItHasAnAddressOrASecret() {
        #expect(PrivateExtenderFields().isEmpty)
        #expect(PrivateExtenderFields(ip: "  ", secret: " ").isEmpty)
        #expect(!PrivateExtenderFields(ip: "192.0.2.1", secret: "").isEmpty)
        #expect(!PrivateExtenderFields(ip: "", secret: "s").isEmpty)
    }

    // MARK: the share payload

    // the screen renders what the sdk built and nothing of its own
    @Test func theSharePassesTheSdkPayloadThrough() {
        let result = SdkExtenderShareResult()
        result.text = "ur-ext:1:AAAA"
        result.count = 12
        result.includesSettings = true
        let share = ExtenderShare(
            text: result.text,
            count: result.count,
            includesSettings: result.includesSettings
        )
        #expect(share.text == "ur-ext:1:AAAA")
        #expect(share.count == 12)
        #expect(share.includesSettings)
        #expect(!share.isEmpty)
    }

    // a space that keys no extender network has nothing to share, and the
    // screen must not offer a code for it
    @Test func anEmptyPayloadIsAnEmptyShare() {
        #expect(ExtenderShare.empty.isEmpty)
        #expect(ExtenderShare.empty.count == 0)
        #expect(extenderShareQrImage("") == nil)
    }

    @Test func aPayloadRendersAQrCode() {
        let image = extenderShareQrImage("ur-ext:1:AAAA")
        #expect(image != nil)
        // level H at this payload length is a small code; what matters is that
        // it is square and non-empty
        if let image {
            #expect(0 < image.width)
            #expect(image.width == image.height)
        }
    }

    // MARK: the import decision

    private func decode(
        ok: Bool = true,
        error: String = "",
        networkHost: String = "bringyour.com",
        foreignHost: Bool = false,
        count: Int = 3,
        hasSettings: Bool = false,
        settingsHost: String = ""
    ) -> ExtenderImportDecision {
        extenderImportDecision(
            ok: ok,
            error: error,
            networkHost: networkHost,
            foreignHost: foreignHost,
            count: count,
            hasSettings: hasSettings,
            settingsHost: settingsHost
        )
    }

    @Test func aPayloadThatIsNotAShareIsInvalid() {
        #expect(decode(ok: false, error: SdkExtenderImportErrorInvalid) == .invalid)
        #expect(decode(ok: false) == .invalid)
        #expect(!extenderImportAllowed(.invalid, useSettings: true))
    }

    @Test func thisNetworksPayloadImportsWithNothingElseAsked() {
        let decision = decode(count: 7)
        #expect(decision == .ready(count: 7, hasSettings: false, settingsHost: "", requiresSettings: false))
        #expect(extenderImportAllowed(decision, useSettings: false))
        #expect(!extenderImportNeedsConfirmation(decision, useSettings: false))
    }

    // K7: a foreign network with no settings block could never be verified
    // here, so the import is refused outright
    @Test func aForeignPayloadWithoutSettingsIsRefused() {
        let decision = decode(networkHost: "other.example.com", foreignHost: true)
        #expect(decision == .foreignWithoutSettings(networkHost: "other.example.com"))
        #expect(!extenderImportAllowed(decision, useSettings: false))
        #expect(!extenderImportAllowed(decision, useSettings: true))
        #expect(!extenderImportNeedsConfirmation(decision, useSettings: true))
    }

    // K7: a foreign network's addresses are taken only together with its
    // settings, and that replacement is confirmed first
    @Test func aForeignPayloadWithSettingsNeedsTheSettingsAndAConfirmation() {
        let decision = decode(
            networkHost: "other.example.com",
            foreignHost: true,
            count: 4,
            hasSettings: true,
            settingsHost: "extender.other.example.com"
        )
        #expect(decision == .ready(
            count: 4,
            hasSettings: true,
            settingsHost: "extender.other.example.com",
            requiresSettings: true
        ))
        #expect(!extenderImportAllowed(decision, useSettings: false))
        #expect(extenderImportAllowed(decision, useSettings: true))
        #expect(extenderImportNeedsConfirmation(decision, useSettings: true))
    }

    // this network's own payload may still carry settings; taking them is
    // optional, and taking them is still confirmed
    @Test func thisNetworksPayloadWithSettingsMayBeImportedEitherWay() {
        let decision = decode(hasSettings: true, settingsHost: "extender.bringyour.com")
        #expect(extenderImportAllowed(decision, useSettings: false))
        #expect(extenderImportAllowed(decision, useSettings: true))
        #expect(!extenderImportNeedsConfirmation(decision, useSettings: false))
        #expect(extenderImportNeedsConfirmation(decision, useSettings: true))
    }

    // the decision reads the sdk result's fields, in the sdk's spelling
    @Test func theDecisionComesFromTheSdkResult() {
        let result = SdkExtenderShareDecodeResult()
        result.ok = true
        result.networkHost = "other.example.com"
        result.foreignHost = true
        result.count = 9
        result.hasSettings = true
        result.settingsHost = "extender.other.example.com"
        #expect(extenderImportDecision(result) == .ready(
            count: 9,
            hasSettings: true,
            settingsHost: "extender.other.example.com",
            requiresSettings: true
        ))

        let invalid = SdkExtenderShareDecodeResult()
        invalid.error = SdkExtenderImportErrorInvalid
        #expect(extenderImportDecision(invalid) == .invalid)
    }

    @Test func theImportErrorIdsAreTheSdkIds() {
        #expect(SdkExtenderImportErrorInvalid == "import_extenders_invalid")
        #expect(SdkExtenderImportErrorForeignHost == "import_extenders_foreign_host")
    }
}
