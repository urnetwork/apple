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
 * states in place of the list, the client groups' headers, counts and row
 * labels, and the confirmations. Times are formatted in en_US and UTC
 * against a fixed clock.
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
            ("extension", "Browser extension", .web),
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
                ipFamilyLabel: "",
                extenders: []
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
    }

    // §5: a rejected sign-in is its own state with its own wording, not the
    // load-failed text and its Try again. The SDK reports it on an empty
    // snapshot once the credential is gone; the app's logout flow follows.
    @Test func signInRequiredSaysToSignInAgain() {
        var snapshot = SessionsSnapshot()
        snapshot.error = SessionErrorItem(signInRequired: true)
        #expect(snapshot.content == .signInRequired)
        #expect(snapshot.signInRequiredMessage == "Sign in again to manage sessions.")
        #expect(!snapshot.refreshFailed)

        // a poll or pull keeps it rather than showing progress
        snapshot.loading = true
        #expect(snapshot.content == .signInRequired)

        // an earlier list can no longer be managed either
        snapshot.loading = false
        snapshot.loaded = true
        snapshot.sessions = [Self.session()]
        #expect(snapshot.content == .signInRequired)
        #expect(!snapshot.refreshFailed)
        snapshot.refreshing = true
        #expect(snapshot.content == .signInRequired)

        // an unsupported server still says so
        snapshot.supported = false
        #expect(snapshot.content == .unsupported)
    }

    // the controller's trusted cause; it never sets it for this session
    // signed out here, which keeps the generic wording
    @Test func aSessionSignedOutFromAnotherDeviceSaysSo() {
        var snapshot = SessionsSnapshot()
        snapshot.error = SessionErrorItem(signInRequired: true, sessionRevoked: true)
        #expect(snapshot.content == .signInRequired)
        #expect(snapshot.signInRequiredMessage == "This session was signed out from another device.")
    }

    // a retryable failure is still a failed load with Try again
    @Test func onlySignInRequiredLeavesTheLoadFailedState() {
        var snapshot = SessionsSnapshot()
        for error in [SessionErrorItem(), SessionErrorItem(retryable: true)] {
            snapshot.error = error
            #expect(snapshot.content == .loadFailed)
        }
    }

    @Test func aFailedRefreshKeepsTheListWithANotice() {
        var snapshot = SessionsSnapshot()
        snapshot.loaded = true
        snapshot.sessions = [Self.session()]
        snapshot.sessionCount = 1
        snapshot.error = SessionErrorItem(retryable: true)
        #expect(snapshot.content == .list)
        #expect(snapshot.refreshFailed)

        snapshot.sessions = []
        snapshot.sessionCount = 0
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

    // §5 C: empty only with no device sign-in and no group; a list of client
    // sessions alone, or of sign-ins past the shown page, is a list
    @Test func emptyMeansNoSignInAndNoGroup() {
        var snapshot = SessionsSnapshot()
        snapshot.loaded = true
        snapshot.groups = [SessionGroupItem(kind: SdkClientSessionGroupHostedProxies, count: 3)]
        #expect(snapshot.content == .list)

        snapshot.groups = []
        snapshot.sessionCount = 1
        #expect(snapshot.content == .list)

        snapshot.sessionCount = 0
        #expect(snapshot.content == .empty)
    }

    // §4: a failed sign-out of the other sessions says so under the button,
    // which stays; a retry in flight shows progress instead
    @Test func aFailedSignOutOfTheOtherSessionsSaysSoUnderTheButton() {
        var snapshot = SessionsSnapshot()
        snapshot.loaded = true
        snapshot.sessions = [
            SessionItem(id: Self.sessionId, current: true, kind: "google"),
            SessionItem(id: "02b2e4d3-0000-4000-8000-00000000000b", kind: "password"),
        ]
        snapshot.sessionCount = 2
        snapshot.otherSessionCount = 1
        #expect(snapshot.showsSignOutOthers)
        #expect(snapshot.signOutOthersFailedMessage == nil)

        snapshot.bulkAction = SessionActionItem(loading: true)
        #expect(snapshot.signOutOthersFailedMessage == nil)

        for error in [SessionErrorItem(), SessionErrorItem(retryable: true)] {
            snapshot.bulkAction = SessionActionItem(error: error)
            #expect(snapshot.signOutOthersFailed)
            #expect(!snapshot.signingOutOthers)
            #expect(snapshot.signOutOthersFailedMessage == "Couldn't sign out the other sessions. Try again.")
        }

        snapshot.bulkAction = SessionActionItem(pending: true, error: SessionErrorItem(retryable: true))
        #expect(snapshot.signingOutOthers)
        #expect(snapshot.signOutOthersFailedMessage == nil)

        // a row's failure is the row's own
        snapshot.bulkAction = nil
        snapshot.actions = [SessionActionItem(sessionId: Self.sessionId, error: SessionErrorItem())]
        #expect(snapshot.signOutOthersFailedMessage == nil)
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
        let withPlace = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "Android", place: "Chicago, Illinois, United States", current: false, hostedProxy: false)
        #expect(withPlace.title == "Sign out this session?")
        #expect(withPlace.message == "Android in Chicago, Illinois, United States will be signed out.")

        let noPlace = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "Unknown device", place: "", current: false, hostedProxy: false)
        #expect(noPlace.message == "Unknown device will be signed out.")

        let current = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "iOS", place: "Chicago", current: true, hostedProxy: false)
        #expect(current.title == "Sign out this session?")
        #expect(current.message == "This is the session you're using. This app will be signed out.")

        let others = SessionsConfirmation.signOutOthers(keepsHostedProxies: false)
        #expect(others.title == "Sign out all other sessions?")
        #expect(others.message == "Every other session in this list will be signed out. This session stays signed in. Anyone who knows your sign-in details can still sign in again.")
        // §4: never "all devices signed out"
        #expect(!others.message.localizedCaseInsensitiveContains("all devices"))
    }

    // §5 C: a hosted proxy's sign-out says the proxy stops working, and the
    // bulk sign-out says it keeps hosted proxies while the list has them
    @Test func hostedProxyConfirmationsSayWhatHappensToTheProxies() {
        let proxy = SessionsConfirmation.signOut(sessionId: Self.sessionId, device: "Hosted proxy", place: "Chicago", current: false, hostedProxy: true)
        #expect(proxy.title == "Sign out this session?")
        #expect(proxy.message == "This hosted proxy will stop working. Create a new one to replace it.")
        #expect(proxy.message(keyNeedsBackup: true) == proxy.message)

        let others = SessionsConfirmation.signOutOthers(keepsHostedProxies: true)
        #expect(others.title == "Sign out all other sessions?")
        #expect(others.message == "Every other session in this list will be signed out, except hosted proxies. This session stays signed in. Anyone who knows your sign-in details can still sign in again.")
        #expect(!others.message.localizedCaseInsensitiveContains("all devices"))
    }

    // MARK: Groups

    // §5 C: each kind's header with its count, and an unknown kind as other
    // clients
    @Test func everyGroupHasItsHeaderAndRowLabel() {
        let cases: [(String, SessionGroupKind, String, String)] = [
            (SdkClientSessionGroupHostedProxies, .hostedProxies, "Hosted proxies (7)", "Hosted proxy"),
            (SdkClientSessionGroupApiClients, .apiClients, "API clients (7)", "API client"),
            (SdkClientSessionGroupPairedDevices, .pairedDevices, "Paired devices (7)", "Paired device"),
            (SdkClientSessionGroupOtherClients, .otherClients, "Other clients (7)", "Other client"),
            ("future_clients", .otherClients, "Other clients (7)", "Other client"),
        ]
        let snapshot = SessionsSnapshot()
        for (kind, groupKind, title, rowLabel) in cases {
            #expect(SessionGroupKind(kind) == groupKind, "kind \(kind)")
            let group = SessionGroupItem(kind: kind, count: 7)
            #expect(snapshot.title(of: group, locale: Locale(identifier: "en_US")) == title, "kind \(kind)")
            #expect(groupKind.rowLabel == rowLabel, "kind \(kind)")
        }
    }

    // §4: {count} in the locale's grouping, with "+" while the counts are
    // lower bounds
    @Test func aGroupsCountIsGroupedForTheLocaleWithAPlusWhileTruncated() {
        let english = Locale(identifier: "en_US")
        #expect(SessionLabels.count(1_234, truncated: false, locale: english) == "1,234")
        #expect(SessionLabels.count(1_234, truncated: true, locale: english) == "1,234+")
        #expect(SessionLabels.count(12, truncated: false, locale: english) == "12")
        #expect(SessionLabels.count(1_234, truncated: false, locale: Locale(identifier: "de_DE")) == "1.234")

        var snapshot = SessionsSnapshot()
        let group = SessionGroupItem(kind: SdkClientSessionGroupHostedProxies, count: 10_000)
        #expect(snapshot.title(of: group, locale: english) == "Hosted proxies (10,000)")
        snapshot.truncated = true
        #expect(snapshot.title(of: group, locale: english) == "Hosted proxies (10,000+)")
    }

    // §5 C: a group's rows are sign-in rows with line 1's device label
    // replaced by the group's row label, the app version still appended; the
    // logo, place, times and ID are the row's own
    @Test func aGroupsRowsReadAsTheGroup() throws {
        let session = Self.session(kind: "api_key_client", lastUsed: Self.lastUsed(deviceType: "cli", appVersion: "1.4.0"))
        let snapshot = SessionsSnapshot()
        let group = SessionGroupItem(kind: SdkClientSessionGroupApiClients, count: 1, expanded: true, sessions: [session])
        let row = try #require(snapshot.rows(in: group, now: Self.now, format: Self.format).first)
        #expect(row.title == "API client · 1.4.0")
        #expect(row.device == "API client")
        #expect(row.signOutActionName == "Sign out API client")
        #expect(row.icon == .cli)
        #expect(row.place == "Chicago, Illinois, United States")
        #expect(row.signIn == "Signed in Sep 26 · API key · ID 01a1f3c2")

        let proxy = SessionRowPresentation(
            Self.session(kind: "legacy_proxy", lastUsed: Self.lastUsed(deviceType: "server", appVersion: "")),
            group: .hostedProxies,
            snapshot: snapshot,
            now: Self.now,
            format: Self.format
        )
        #expect(proxy.title == "Hosted proxy")
        #expect(proxy.icon == .server)
        // a sign-in row keeps the device type's label
        #expect(Self.row(Self.session(lastUsed: Self.lastUsed(deviceType: "cli", appVersion: "1.4.0"))).title == "Command line · 1.4.0")
    }

    // the screen's lookups: a row on screen in a group carries its kind, and
    // the list has hosted proxies only with their group
    @Test func aListedRowKnowsItsGroup() throws {
        var snapshot = SessionsSnapshot()
        snapshot.sessions = [SessionItem(id: Self.sessionId, current: true, kind: "google")]
        let proxyId = "02b2e4d3-0000-4000-8000-00000000000b"
        snapshot.groups = [SessionGroupItem(kind: SdkClientSessionGroupHostedProxies, count: 1, expanded: true, sessions: [SessionItem(id: proxyId, kind: "legacy_proxy")])]
        let signIn = try #require(snapshot.listedSession(Self.sessionId))
        #expect(signIn.session.id == Self.sessionId)
        #expect(signIn.group == nil)
        let proxy = try #require(snapshot.listedSession(proxyId))
        #expect(proxy.session.id == proxyId)
        #expect(proxy.group == .hostedProxies)
        #expect(snapshot.listedSession("03c3d5e4-0000-4000-8000-00000000000c")?.session.id == nil)
        #expect(snapshot.hasHostedProxies)

        snapshot.groups = [SessionGroupItem(kind: SdkClientSessionGroupApiClients, count: 2)]
        #expect(!snapshot.hasHostedProxies)
    }

    // §5 C: Sign out all other sessions shows with this app's session and a
    // positive count from the controller, which leaves out hosted proxies
    @Test func signOutOthersShowsWithThisSessionAndAPositiveCount() {
        var snapshot = SessionsSnapshot()
        snapshot.loaded = true
        snapshot.sessions = [SessionItem(id: Self.sessionId, current: true, kind: "google")]
        snapshot.sessionCount = 1
        snapshot.groups = [SessionGroupItem(kind: SdkClientSessionGroupHostedProxies, count: 5)]
        #expect(!snapshot.showsSignOutOthers)

        snapshot.otherSessionCount = 2
        #expect(snapshot.showsSignOutOthers)

        // no current session listed
        snapshot.sessions = [SessionItem(id: Self.sessionId, current: false, kind: "google")]
        #expect(!snapshot.showsSignOutOthers)
    }
}
