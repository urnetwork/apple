//
//  OnboardingDeepLinks.swift
//  URnetwork
//
//  Where an onboarding email's link takes the app once the ur.io landing page
//  has logged the click and opened it: `urnetwork://onboarding/<step>`, with
//  the feedback link's one-tap answer (`?r=<1-5>` or `?why=<reason>`) and the
//  campaign token (`?t=`) carried along. Compiled into the app only.
//

import Foundation

enum OnboardingDestination: Equatable {
    case connect
    case widgets
    case offer
    case feedback(rating: Int?, reason: String?, token: String?)

    static let scheme = "urnetwork"
    static let host = "onboarding"

    /// The destination a URL names, or nil for any other URL the app opens.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let name = url.pathComponents.dropFirst().first?.lowercased() else {
            return nil
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? {
            query.first(where: { $0.name == key })?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch name {
        case "connect":
            self = .connect
        case "widgets":
            self = .widgets
        case "offer":
            self = .offer
        case "feedback":
            let rating = value("r").flatMap(Int.init).flatMap { (1...5).contains($0) ? $0 : nil }
            self = .feedback(rating: rating, reason: value("why"), token: value("t"))
        default:
            return nil
        }
    }
}

/// What the feedback screen starts with when an email's one-tap answer opened it.
struct FeedbackPrefill: Equatable {
    var rating: Int?
    var reason: String?
    var token: String?

    /// The reason as the feedback text, in the user's language.
    var reasonText: String? {
        switch reason {
        case "not_needed": return String(localized: "I didn't need it yet")
        case "not_working": return String(localized: "It didn't work")
        case "trust": return String(localized: "I'm not sure I trust a VPN")
        case "other": return String(localized: "Something else")
        default: return nil
        }
    }
}
