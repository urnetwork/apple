//
//  OpenURnetworkIntent.swift
//  URnetwork
//
//  Opens the app. Used by the quick connect control and the widgets when the
//  tunnel configuration does not exist yet (fresh install, logged out): only
//  the app can create the configuration and obtain the system's VPN consent.
//
//  Compiled into both the app and the widget extension: the system requires
//  an intent that opens the app to be a member of both targets.
//

import AppIntents

struct OpenURnetworkIntent: AppIntent {

    static let title: LocalizedStringResource = "Open URnetwork"

    static let isDiscoverable: Bool = false

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
