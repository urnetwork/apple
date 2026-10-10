//
//  SessionsPresentationTests.swift
//  networkTests
//

import Foundation
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
import URnetworkSdk
@testable import URnetwork

/**
 * What a row of Account > Sessions says (REVOKE-UI-FINAL.md §3, §5, §10): the
 * device label and logo for every device type, the method for every sign-in
 * kind, the country color, the short ID, Last used across every unit up to
 * the 7-day date cutoff, the full date and time a screen reader hears, the
 * states in place of the list, and the confirmations. Times are formatted in
 * en_US and UTC against a fixed clock.
 */
struct SessionsPresentationTests {

    // test-only session id
    private static let sessionId = "01a1f3c2-5b6d-4e7f-8a9b-0c1d2e3f4a5b"

    // 2026-10-03 04:00:00 UTC
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    private static let format = SessionTimeFormat(
        locale: Locale(identifier: "en_US"),
        timeZone: TimeZone(identifier: "UTC")!,
        calendar: Calendar(identifier: .gregorian)
    )

    private static func lastUsed(
        secondsAgo: Int64 = 300,
        city: String = "Chicago",
        region: String = "Illinois",
        country: String = "United States",
        countryCode: String = "us",
        deviceType: String = "android",
        appVersion: String = "2026.10.8-1067"
    ) -> SessionLastUsedItem {
        SessionLastUsedItem(
            unixTime: Int64(now.timeIntervalSince1970) - secondsAgo,
            city: city,
            region: region,
            country: country,
            countryCode: countryCode,
            deviceType: deviceType,
            appVersion: appVersion
        )
    }

    private static func row(
        _ session: SessionItem,
        snapshot: SessionsSnapshot = SessionsSnapshot()
    ) -> SessionRowPresentation {
        SessionRowPresentation(session, snapshot: snapshot, now: now, format: format)
    }

    private static func session(
        kind: String = "google",
        createTimeMillis: Int64? = 1_790_400_000_000,
        lastUsed: SessionLastUsedItem? = SessionsPresentationTests.lastUsed()
    ) -> SessionItem {
        SessionItem(id: sessionId, current: false, kind: kind, createTimeMillis: createTimeMillis, lastUsed: lastUsed)
    }

    private static func relativeFormatter(_ style: RelativeDateTimeFormatter.DateTimeStyle) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = format.locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = style
        return formatter
    }

    // MARK: Device and method labels

    @Test func everyDeviceTypeHasItsLabelAndLogo() {
        let cases: [(String, String, SessionDeviceIcon)] = [
            ("android", "Android", .android),
            ("ios", "iOS", .apple),
            ("macos", "macOS", .apple),
            ("windows", "Windows", .windows),
            ("linux", "Linux", .linux),
            ("web", "Web", .web),
            ("cli", "Command line", .cli),
            ("server", "Server", .server),
            ("unknown", "Unknown device", .unknown),
            ("", "Unknown device", .unknown),
            ("toaster", "Unknown device", .unknown),
            ("IOS", "Unknown device", .unknown),
        ]
        for (deviceType, label, icon) in cases {
            let device = SessionLabels.device(deviceType)
            #expect(device.label == label, "device type \(deviceType)")
            #expect(device.icon == icon, "device type \(deviceType)")
        }
    }

    @Test func everyDeviceLogoIsATemplateAsset() {
        #expect(SessionDeviceIcon.allCases.map(\.assetName) == [
            "ur.symbols.device.android",
            "ur.symbols.device.apple",
            "ur.symbols.device.windows",
            "ur.symbols.device.linux",
            "ur.symbols.device.web",
            "ur.symbols.device.cli",
            "ur.symbols.device.server",
            "ur.symbols.device.unknown",
        ])
    }

    // the Account row's face takes the row's icon tint and the device logos
    // are drawn white: template assets, the size of the other Account icons
    @Test func theGlyphsAreTemplateAssets() throws {
        #if canImport(UIKit)
        let accountIconSize = try #require(UIImage(named: "ur.symbols.user.circle")).size
        for name in ["ur.symbols.session.face"] + SessionDeviceIcon.allCases.map(\.assetName) {
            let image = try #require(UIImage(named: name), "\(name) is missing")
            #expect(image.renderingMode == .alwaysTemplate, "\(name)")
            #expect(image.size == accountIconSize, "\(name)")
        }
        #endif
    }

    @Test func everySignInKindHasItsMethodLabel() {
        let cases: [(String, String?)] = [
            ("password", "Password"),
            ("verify", "Verification code"),
            ("apple", "Apple"),
            ("google", "Google"),
            ("sso", "Single sign-on"),
            ("wallet", "Wallet"),
            ("seedphrase", "Recovery phrase"),
            ("signup", "New account"),
            ("auth_code", "Auth code"),
            ("device_adopt", "Device pairing"),
            ("api_key_client", "API key"),
            // legacy kinds and kinds this app does not know name no method
            ("legacy", nil),
            ("legacy_proxy", nil),
            ("", nil),
            ("future_kind", nil),
        ]
        for (kind, label) in cases {
            #expect(SessionLabels.method(kind) == label, "kind \(kind)")
        }
    }

    // MARK: Row lines

    @Test func aRowHasItsThreeLines() {
        let row = Self.row(Self.session())
        #expect(row.title == "Android · 2026.10.8-1067")
        #expect(row.lastUse == "Chicago, Illinois, United States · Last used \(Self.format.lastUsed(Self.now.addingTimeInterval(-300), now: Self.now))")
        #expect(row.signIn == "Signed in Sep 26 · Google · ID 01a1f3c2")
        #expect(row.icon == .android)
        #expect(row.device == "Android")
        #expect(row.place == "Chicago, Illinois, United States")
    }

    @Test func lineOneLeavesOutAnUnknownVersion() {
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(appVersion: ""))).title == "Android")
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(appVersion: "  "))).title == "Android")
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(deviceType: "macos", appVersion: "2026.10.8-1066894190"))).title == "macOS · 2026.10.8-1066894190")
    }

    @Test func lineTwoLeavesOutUnknownPlaceParts() {
        let used = "Last used \(Self.format.lastUsed(Self.now.addingTimeInterval(-300), now: Self.now))"
        let cases: [(String, String, String, String)] = [
            ("", "Illinois", "United States", "Illinois, United States · \(used)"),
            ("Chicago", "", "United States", "Chicago, United States · \(used)"),
            ("", "", "United States", "United States · \(used)"),
            ("", "", "", used),
        ]
        for (city, region, country, expected) in cases {
            let row = Self.row(Self.session(lastUsed: Self.lastUsed(city: city, region: region, country: country)))
            #expect(row.lastUse == expected)
        }
    }

    // §3: LastUsed == nil
    @Test func aSessionWithNoObservedUseSaysSo() {
        let row = Self.row(Self.session(lastUsed: nil))
        #expect(row.lastUse == "Last use unavailable")
        #expect(row.lastUseAccessibilityLabel == "Last use unavailable")
        #expect(row.title == "Unknown device")
        #expect(row.icon == .unknown)
        #expect(row.place.isEmpty)
        #expect(row.colorHex == "0099FF")
    }

    // long places and versions are text, kept whole for the row to wrap
    @Test func longPlacesAndVersionsAreKeptWhole() {
        let city = String(repeating: "Llanfairpwllgwyngyll ", count: 8).trimmingCharacters(in: .whitespaces)
        let version = String(repeating: "9", count: 64)
        let row = Self.row(Self.session(lastUsed: Self.lastUsed(city: city, appVersion: version)))
        #expect(row.title == "Android · \(version)")
        #expect(row.lastUse.hasPrefix("\(city), Illinois, United States · "))
    }

    @Test func lineThreeLeavesOutTheMethodOfLegacyKinds() {
        #expect(Self.row(Self.session(kind: "legacy")).signIn == "Signed in Sep 26 · ID 01a1f3c2")
        #expect(Self.row(Self.session(kind: "legacy_proxy")).signIn == "Signed in Sep 26 · ID 01a1f3c2")
        #expect(Self.row(Self.session(kind: "sso", createTimeMillis: nil)).signIn == "Single sign-on · ID 01a1f3c2")
    }

    // §1.3: the first 8 characters are shown; the copy is the full ID
    @Test func theRowShowsEightCharactersAndCopiesTheWholeId() {
        let row = Self.row(Self.session())
        #expect(row.shortId == "01a1f3c2")
        #expect(row.id == Self.sessionId)
        #expect(row.signIn.hasSuffix("ID 01a1f3c2"))
        #expect(!row.signIn.contains(Self.sessionId))
    }

    @Test func thisAppsSessionIsTagged() {
        let current = SessionItem(id: Self.sessionId, current: true, kind: "google")
        #expect(Self.row(current).isCurrent)
        #expect(!Self.row(Self.session()).isCurrent)

        // by the snapshot's current session id as well
        var snapshot = SessionsSnapshot()
        snapshot.currentSessionId = Self.sessionId
        #expect(Self.row(Self.session(), snapshot: snapshot).isCurrent)
    }

    @Test func theScreenReaderActionNamesTheDevice() {
        #expect(Self.row(Self.session()).signOutActionName == "Sign out Android")
        #expect(Self.row(Self.session(lastUsed: nil)).signOutActionName == "Sign out Unknown device")
    }

    // MARK: Country color

    // the SDK's color for the country code, the unknown-country blue for an
    // empty one: what providerDotColor colors a provider's dot with
    @Test func theCountryCircleIsTheCountrysColor() {
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(countryCode: "us"))).colorHex == SdkGetColorHex("us"))
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(countryCode: "de"))).colorHex == SdkGetColorHex("de"))
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(countryCode: ""))).colorHex == "0099FF")
        #expect(countryDotColorHex("US") == SdkGetColorHex("us"))

        for countryCode in ["us", "de", ""] {
            let provider = ProviderLocationRow(
                clientId: SdkNewId()!,
                country: "",
                countryCode: countryCode,
                region: "",
                city: "",
                hasLocation: true,
                lat: nil,
                lon: nil,
                connectedSinceMillis: 0,
                ipFamilyLabel: ""
            )
            #expect(providerDotColor(provider) == Color(hex: countryDotColorHex(countryCode)))
        }
    }

    // MARK: Times

    // §3.1: now under 5 seconds, then seconds, minutes, hours and days up to
    // 7 days, then a date
    @Test func lastUsedRunsThroughEveryUnitToTheDateCutoff() {
        let day: TimeInterval = 24 * 60 * 60
        let cases: [(TimeInterval, SessionRelativeTime)] = [
            (0, .now),
            (4.9, .now),
            // a use stamped ahead of this clock
            (-30, .now),
            (5, .seconds(5)),
            (59, .seconds(59)),
            (60, .minutes(1)),
            (3_599, .minutes(59)),
            (3_600, .hours(1)),
            (day - 1, .hours(23)),
            (day, .days(1)),
            (7 * day - 1, .days(6)),
            (7 * day, .date),
            (400 * day, .date),
        ]
        for (elapsed, expected) in cases {
            #expect(SessionRelativeTime(Self.now.addingTimeInterval(-elapsed), now: Self.now) == expected, "elapsed \(elapsed)")
        }
    }

    // the system's abbreviated relative time, in the past
    @Test func relativeTimesAreTheSystemsAbbreviatedForms() {
        let named = Self.relativeFormatter(.named)
        let numeric = Self.relativeFormatter(.numeric)
        let cases: [(TimeInterval, String)] = [
            (2, named.localizedString(fromTimeInterval: 0)),
            (12, numeric.localizedString(from: DateComponents(second: -12))),
            (5 * 60 + 30, numeric.localizedString(from: DateComponents(minute: -5))),
            (3 * 60 * 60, numeric.localizedString(from: DateComponents(hour: -3))),
            (6 * 24 * 60 * 60, numeric.localizedString(from: DateComponents(day: -6))),
        ]
        for (elapsed, expected) in cases {
            let text = Self.format.lastUsed(Self.now.addingTimeInterval(-elapsed), now: Self.now)
            #expect(text == expected, "elapsed \(elapsed)")
        }
        #expect(Self.format.lastUsed(Self.now, now: Self.now) == "now")
        #expect(Self.format.lastUsed(Self.now.addingTimeInterval(-12), now: Self.now).contains("12"))
        #expect(Self.format.lastUsed(Self.now.addingTimeInterval(-6 * 24 * 60 * 60), now: Self.now).contains("6"))
    }

    @Test func fromSevenDaysLastUsedIsADate() {
        let sevenDaysAgo = Self.now.addingTimeInterval(-7 * 24 * 60 * 60)
        #expect(Self.format.lastUsed(sevenDaysAgo, now: Self.now) == "Sep 26")
        #expect(Self.format.lastUsed(sevenDaysAgo, now: Self.now) == Self.format.date(sevenDaysAgo, now: Self.now))
    }

    @Test func aDateHasTheYearOnlyWhenItIsAnotherYear() {
        // 2025-10-03
        let lastYear = Date(timeIntervalSince1970: 1_759_464_000)
        #expect(Self.format.date(Self.now, now: Self.now) == "Oct 3")
        #expect(Self.format.date(lastYear, now: Self.now) == "Oct 3, 2025")
    }

    // LastUsed.UnixTime is in seconds, CreateTime in milliseconds
    @Test func theTimesAreReadInTheirUnits() {
        let row = Self.row(Self.session(createTimeMillis: 1_790_400_000_000, lastUsed: Self.lastUsed(secondsAgo: 3 * 60 * 60)))
        let threeHours = Self.relativeFormatter(.numeric).localizedString(from: DateComponents(hour: -3))
        #expect(row.lastUse.hasSuffix("Last used \(threeHours)"))
        // 1_790_400_000 s: 2026-09-26 05:20 UTC
        #expect(row.signIn.hasPrefix("Signed in Sep 26 · "))
    }

    // §3.1: every relative time or date reads as the full date and time
    @Test func screenReadersHearTheFullDateAndTime() {
        let row = Self.row(Self.session())
        let usedAt = Self.now.addingTimeInterval(-300)
        let signedInAt = Date(timeIntervalSince1970: 1_790_400_000)
        #expect(row.lastUseAccessibilityLabel == "Chicago, Illinois, United States, Last used \(Self.format.full(usedAt))")
        #expect(row.signInAccessibilityLabel == "Signed in \(Self.format.full(signedInAt)), Google, ID 01a1f3c2")
        #expect(Self.format.full(usedAt).contains("2026"))
        #expect(Self.format.full(signedInAt).contains("September 26, 2026"))
    }

    // MARK: States

    @Test func neverLoadedShowsProgress() {
        var snapshot = SessionsSnapshot()
        #expect(snapshot.content == .loading)
        snapshot.loading = true
        #expect(snapshot.content == .loading)
    }

    @Test func aFailedFirstLoadOffersTryAgainAndARetryShowsProgress() {
        var snapshot = SessionsSnapshot()
        snapshot.error = SessionErrorItem(retryable: true)
        #expect(snapshot.content == .loadFailed)
        #expect(!snapshot.refreshFailed)

        // Try again: the controller keeps the error while it loads again
        snapshot.loading = true
        #expect(snapshot.content == .loading)

        // sign-in required uses the same generic wording; the app's own
        // logout flow takes over (the SDK rejected the credential)
        snapshot.loading = false
        snapshot.error = SessionErrorItem(signInRequired: true)
        #expect(snapshot.content == .loadFailed)
    }

    @Test func aFailedRefreshKeepsTheListWithANotice() {
        var snapshot = SessionsSnapshot()
        snapshot.loaded = true
        snapshot.sessions = [Self.session()]
        snapshot.error = SessionErrorItem(retryable: true)
        #expect(snapshot.content == .list)
        #expect(snapshot.refreshFailed)

        snapshot.sessions = []
        #expect(snapshot.content == .empty)
        #expect(snapshot.refreshFailed)

        snapshot.error = nil
        #expect(!snapshot.refreshFailed)
    }

    @Test func anUnsupportedServerSaysSessionsArentAvailable() {
        var snapshot = SessionsSnapshot()
        snapshot.supported = false
        snapshot.error = SessionErrorItem(unsupported: true)
        #expect(snapshot.content == .unsupported)
        #expect(!snapshot.refreshFailed)

        // even with an earlier list
        snapshot.loaded = true
        snapshot.sessions = [Self.session()]
        #expect(snapshot.content == .unsupported)
        #expect(!snapshot.refreshFailed)
    }

    @Test func loadedWithNoSessionsIsEmpty() {
        var snapshot = SessionsSnapshot()
        snapshot.loaded = true
        #expect(snapshot.content == .empty)
        // refreshing keeps what is shown
        snapshot.refreshing = true
        #expect(snapshot.content == .empty)
    }

    // §5: the legacy note only while coverage is partial
    @Test func theLegacyNoteShowsOnlyForPartialCoverage() {
        var snapshot = SessionsSnapshot()
        snapshot.legacyCoverage = "partial"
        #expect(snapshot.legacyCoveragePartial)
        snapshot.legacyCoverage = "complete"
        #expect(!snapshot.legacyCoveragePartial)
        snapshot.legacyCoverage = ""
        #expect(!snapshot.legacyCoveragePartial)
    }

    // MARK: Confirmations

    // §4: every sign-out names the session
    @Test func confirmationsNameTheSession() {
        let withPlace = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "Android", place: "Chicago, Illinois, United States", current: false)
        #expect(withPlace.title == "Sign out this session?")
        #expect(withPlace.message == "Android in Chicago, Illinois, United States will be signed out.")

        let noPlace = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "Unknown device", place: "", current: false)
        #expect(noPlace.message == "Unknown device will be signed out.")

        let current = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "iOS", place: "Chicago", current: true)
        #expect(current.title == "Sign out this session?")
        #expect(current.message == "This is the session you're using. This app will be signed out.")

        let others = SessionsConfirmation.signOutOthers
        #expect(others.title == "Sign out all other sessions?")
        #expect(others.message == "Every other session in this list will be signed out. This session stays signed in. Anyone who knows your sign-in details can still sign in again.")
        // §4: never "all devices signed out"
        #expect(!others.message.localizedCaseInsensitiveContains("all devices"))
    }
}
