//
//  WidgetDeepLinks.swift
//  URnetwork
//
//  Where a tap on a Home Screen widget takes the app. A widget carries one
//  URL (`widgetURL`); the app receives it in `onOpenURL` and routes: the
//  dashboard to the connect tab, the provider globe to the provider details
//  sheet, the contracts widget to the client contract details sheet. The
//  `urnetwork` scheme is already registered by the app (Info.plist
//  CFBundleURLTypes).
//
//  Compiled into the app and the widget extension.
//

import Foundation

enum WidgetDestination: String, CaseIterable {
    case connect
    case providers
    case contracts

    static let scheme = "urnetwork"
    static let host = "widgets"

    /// `urnetwork://widgets/<destination>`
    var url: URL {
        URL(string: "\(Self.scheme)://\(Self.host)/\(rawValue)")!
    }

    /// The destination a URL names, or nil for any other URL the app opens.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let name = url.pathComponents.dropFirst().first,
              let destination = WidgetDestination(rawValue: name) else {
            return nil
        }
        self = destination
    }
}
