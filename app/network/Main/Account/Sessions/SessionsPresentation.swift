//
//  SessionsPresentation.swift
//  URnetwork
//
//  What Account > Sessions says (server/session/REVOKE-UI-FINAL.md §3-§5),
//  as plain values: each row's three lines, its device logo and country
//  color, the times (Last used is relative up to 7 days, then a date) with the
//  full date and time a screen reader speaks instead, the confirmations, and
//  the failed sign-out of the other sessions and sign-in-required text.
//  Pure, so the labels, logos, colors and times are tested without a view.
//  Every string is from the string catalog; server metadata is shown as text.
//

import Foundation

/// The device logos the country circle shows (template assets, drawn white).
enum SessionDeviceIcon: String, CaseIterable {
    case android
    case apple
    case windows
    case linux
    case web
    case cli
    case server
    case unknown

    var assetName: String {
        "ur.symbols.device.\(rawValue)"
    }
}

/// The labels of a session's metadata.
enum SessionLabels {

    /// The label and logo of a reported device type. Anything else, empty
    /// included, is an unknown device.
    static func device(_ deviceType: String) -> (label: String, icon: SessionDeviceIcon) {
        switch deviceType {
        case "android":
            return (String(localized: "Android"), .android)
        case "ios":
            return (String(localized: "iOS"), .apple)
        case "macos":
            return (String(localized: "macOS"), .apple)
        case "windows":
            return (String(localized: "Windows"), .windows)
        case "linux":
            return (String(localized: "Linux"), .linux)
        case "web":
            return (String(localized: "Web"), .web)
        case "cli":
            return (String(localized: "Command line"), .cli)
        case "server":
            return (String(localized: "Server"), .server)
        default:
            return (String(localized: "Unknown device"), .unknown)
        }
    }

    /// The label of how a session signed in; nil for the legacy kinds and any
    /// kind this app does not know, which name no method.
    static func method(_ kind: String) -> String? {
        switch kind {
        case "password":
            return String(localized: "Password")
        case "verify":
            return String(localized: "Verification code")
        case "apple":
            return String(localized: "Apple")
        case "google":
            return String(localized: "Google")
        case "sso":
            return String(localized: "Single sign-on")
        case "wallet":
            return String(localized: "Wallet")
        case "seedphrase":
            return String(localized: "Recovery phrase")
        case "signup":
            return String(localized: "New account")
        case "auth_code":
            return String(localized: "Auth code")
        case "device_adopt":
            return String(localized: "Device pairing")
        case "api_key_client":
            return String(localized: "API key")
        default:
            return nil
        }
    }

    /// "City, Region, Country" without the unknown parts; empty when no part
    /// is known. The location is approximate (GeoLite2).
    static func place(_ lastUsed: SessionLastUsedItem?) -> String {
        guard let lastUsed else {
            return ""
        }
        return [lastUsed.city, lastUsed.region, lastUsed.country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// A Last used time as the row says it: now under 5 seconds, then the count
/// of one unit (seconds, minutes, hours, days) up to 7 days, then a date.
enum SessionRelativeTime: Equatable {
    case now
    case seconds(Int)
    case minutes(Int)
    case hours(Int)
    case days(Int)
    case date

    /// From here on a use is shown as its date.
    static let dateCutoff: TimeInterval = 7 * 24 * 60 * 60

    init(_ date: Date, now: Date) {
        let elapsed = now.timeIntervalSince(date)
        // a use stamped ahead of this device's clock is now too
        if elapsed < 5 {
            self = .now
        } else if elapsed < 60 {
            self = .seconds(Int(elapsed))
        } else if elapsed < 60 * 60 {
            self = .minutes(Int(elapsed / 60))
        } else if elapsed < 24 * 60 * 60 {
            self = .hours(Int(elapsed / (60 * 60)))
        } else if elapsed < Self.dateCutoff {
            self = .days(Int(elapsed / (24 * 60 * 60)))
        } else {
            self = .date
        }
    }
}

/// Formats session times in one locale, calendar and time zone: the user's,
/// unless a test pins them.
struct SessionTimeFormat {
    var locale: Locale = .current
    var timeZone: TimeZone = .current
    var calendar: Calendar = .current

    /// Last used: the system's abbreviated relative time up to 7 days, then
    /// a date.
    func lastUsed(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = zonedCalendar
        formatter.unitsStyle = .abbreviated
        switch SessionRelativeTime(date, now: now) {
        case .now:
            formatter.dateTimeStyle = .named
            return formatter.localizedString(fromTimeInterval: 0)
        case .seconds(let count):
            return formatter.localizedString(from: DateComponents(second: -count))
        case .minutes(let count):
            return formatter.localizedString(from: DateComponents(minute: -count))
        case .hours(let count):
            return formatter.localizedString(from: DateComponents(hour: -count))
        case .days(let count):
            return formatter.localizedString(from: DateComponents(day: -count))
        case .date:
            return self.date(date, now: now)
        }
    }

    /// A date such as "Oct 3", with the year when it is not this year.
    func date(_ date: Date, now: Date) -> String {
        let calendar = zonedCalendar
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    /// The full date and time a screen reader speaks for a relative time or
    /// a date.
    func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = zonedCalendar
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var zonedCalendar: Calendar {
        var calendar = self.calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }
}

/// One row of the list.
struct SessionRowPresentation: Equatable, Identifiable {
    /// the full session id, which Copy session ID copies
    let id: String
    /// the first 8 characters, the only part shown
    let shortId: String
    /// this app's session, tagged This session
    let isCurrent: Bool
    let device: String
    let icon: SessionDeviceIcon
    /// the country circle's color
    let colorHex: String
    /// line 1: "Android · 2026.10.8-1067", without an unknown version
    let title: String
    /// line 2: "Chicago, Illinois, United States · Last used 5m ago"
    let lastUse: String
    let lastUseAccessibilityLabel: String
    /// line 3: "Signed in Oct 3 · Google · ID 01a1f3c2"
    let signIn: String
    let signInAccessibilityLabel: String
    /// the approximate location; empty when unknown
    let place: String
    /// a sign-out is in flight or pending: "Signing out…", control disabled
    let signingOut: Bool
    /// the last sign-out failed
    let signOutFailed: Bool

    init(_ session: SessionItem, snapshot: SessionsSnapshot, now: Date, format: SessionTimeFormat) {
        let lastUsed = session.lastUsed
        let device = SessionLabels.device(lastUsed?.deviceType ?? "")
        let place = SessionLabels.place(lastUsed)
        let action = snapshot.action(for: session.id)

        id = session.id
        shortId = String(session.id.prefix(8))
        isCurrent = snapshot.isCurrent(session)
        self.device = device.label
        icon = device.icon
        colorHex = countryDotColorHex(lastUsed?.countryCode ?? "")
        self.place = place

        let version = (lastUsed?.appVersion ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = version.isEmpty ? device.label : "\(device.label) · \(version)"

        if let lastUsed {
            // the server's Unix seconds
            let usedAt = Date(timeIntervalSince1970: TimeInterval(lastUsed.unixTime))
            let used = String(format: String(localized: "Last used %@"), format.lastUsed(usedAt, now: now))
            let usedSpoken = String(format: String(localized: "Last used %@"), format.full(usedAt))
            lastUse = place.isEmpty ? used : "\(place) · \(used)"
            lastUseAccessibilityLabel = place.isEmpty ? usedSpoken : "\(place), \(usedSpoken)"
        } else {
            lastUse = String(localized: "Last use unavailable")
            lastUseAccessibilityLabel = lastUse
        }

        var signInParts: [String] = []
        var signInSpoken: [String] = []
        if let createTimeMillis = session.createTimeMillis {
            let signedInAt = Date(timeIntervalSince1970: TimeInterval(createTimeMillis) / 1000)
            signInParts.append(String(format: String(localized: "Signed in %@"), format.date(signedInAt, now: now)))
            signInSpoken.append(String(format: String(localized: "Signed in %@"), format.full(signedInAt)))
        }
        if let method = SessionLabels.method(session.kind) {
            signInParts.append(method)
            signInSpoken.append(method)
        }
        let idPart = String(format: String(localized: "ID %@"), shortId)
        signInParts.append(idPart)
        signInSpoken.append(idPart)
        signIn = signInParts.joined(separator: " · ")
        signInAccessibilityLabel = signInSpoken.joined(separator: ", ")

        signingOut = action?.inProgress ?? false
        signOutFailed = !signingOut && action?.error != nil
    }

    /// The screen-reader action that signs the row out: "Sign out Android".
    var signOutActionName: String {
        String(format: String(localized: "Sign out %@"), device)
    }
}

extension SessionsSnapshot {

    /// The rows, in the controller's order.
    func rows(now: Date, format: SessionTimeFormat) -> [SessionRowPresentation] {
        sessions.map { SessionRowPresentation($0, snapshot: self, now: now, format: format) }
    }

    /// The line under Sign out all other sessions once that sign-out failed;
    /// nil otherwise. The button stays enabled for another try.
    var signOutOthersFailedMessage: String? {
        guard signOutOthersFailed else {
            return nil
        }
        return String(localized: "Couldn't sign out the other sessions. Try again.")
    }

    /// The sign-in-required state (§5): the generic wording, or that another
    /// device signed this session out when the controller reports that
    /// trusted cause.
    var signInRequiredMessage: String {
        if error?.sessionRevoked == true {
            return String(localized: "This session was signed out from another device.")
        }
        return String(localized: "Sign in again to manage sessions.")
    }
}

extension SessionsConfirmation {

    var title: String {
        switch self {
        case .signOut:
            return String(localized: "Sign out this session?")
        case .signOutOthers:
            return String(localized: "Sign out all other sessions?")
        }
    }

    var message: String {
        switch self {
        case .signOut(_, let device, let place, let current):
            if current {
                return String(localized: "This is the session you're using. This app will be signed out.")
            }
            if place.isEmpty {
                return String(format: String(localized: "%@ will be signed out."), device)
            }
            return String(format: String(localized: "%@ in %@ will be signed out."), device, place)
        case .signOutOthers:
            return String(localized: "Every other session in this list will be signed out. This session stays signed in. Anyone who knows your sign-in details can still sign in again.")
        }
    }
}
