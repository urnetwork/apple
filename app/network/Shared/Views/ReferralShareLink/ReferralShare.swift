//
//  ReferralShare.swift
//  URnetwork
//
//  The referral invitation (support inbox 1698): the localized message, which
//  names the code, then the code's ur.io/c link on its own line. The sdk's
//  ConnectLinkUrl builds the link; ur.io/c opens the Android app (or Play,
//  with the link as the install referrer) with the code, and web signup
//  everywhere else. The code stays in the message: installs from the App
//  Store, F-Droid or a dApp store carry no referrer and still type it.
//

import Foundation
import URnetworkSdk

/// The invitation's text and its link.
enum ReferralShare {

    // RFC 3986 unreserved: everything else in a code is percent-encoded, so a
    // code never adds a parameter to the link
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// The connect-link target of a referral code (ConnectLinkUrl gives
    /// https://<link host>/c?bonus=<code>).
    static func linkTarget(code: String) -> String {
        "bonus=" + (code.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")
    }

    /// The message, then the link on its own line; the message alone without
    /// a link.
    static func text(message: String, link: String?) -> String {
        guard let link, !link.isEmpty else {
            return message
        }
        return "\(message)\n\(link)"
    }

    /// The invitation for `code` in this network space.
    static func text(code: String, networkSpace: SdkNetworkSpace?) -> String {
        text(
            message: String(localized: "Join me on URnetwork! Get the app and enter referral code \(code) when you sign up."),
            link: networkSpace?.connectLinkUrl(linkTarget(code: code))
        )
    }
}
