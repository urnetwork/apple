//
//  SupportContact.swift
//  URnetwork
//

import Foundation

/// The support channels the app offers. Discord is unreachable in some regions,
/// so every surface that offers Discord for support also offers the email address.
enum SupportContact {
    static let email = "support@ur.io"
    static let emailUrl = URL(string: "mailto:\(email)")!
    static let discordUrl = URL(string: "https://discord.com/invite/RUNZXMwPRK")!
}
