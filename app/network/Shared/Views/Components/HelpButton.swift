//
//  HelpButton.swift
//  URnetwork
//
//  A small '?' beside a term users find unclear (providing, the usage bar's
//  Pending, extenders) that explains it in an alert with Got it, in the style
//  of the kill switch exception's info button (KillSwitchLabel).
//

import SwiftUI

/// The terms a `HelpButton` explains. The title heads the alert and is the
/// button's accessible name; the message is the short explanation.
enum HelpTopic {
    /// beside the provide mode, wherever it is picked
    case providing
    /// beside the usage bar's Pending
    case pending
    /// beside Account > Extenders
    case extender

    var title: String {
        switch self {
        case .providing:
            return String(localized: "What is providing?")
        case .pending:
            return String(localized: "What is Pending?")
        case .extender:
            return String(localized: "What is an extender?")
        }
    }

    var message: String {
        switch self {
        case .providing:
            return String(localized: "Providing shares some of your internet with other URnetwork members: their traffic can go out through your connection. Providers can earn rewards for the data they share. Provide mode sets when this device provides, and you can stop at any time.")
        case .pending:
            return String(localized: "Pending is data set aside for your open connections. What they don't use goes back to your available data when they close.")
        case .extender:
            return String(localized: "An extender relays your connection to URnetwork where it is blocked. Your traffic stays encrypted through it, and the extender can't read it.")
        }
    }
}

/// The '?' that opens a topic's explanation. Plain styled, so in a row or a
/// label with its own action it takes only its own taps.
struct HelpButton: View {

    @EnvironmentObject var themeManager: ThemeManager
    @State private var isPresented = false

    let topic: HelpTopic

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.small)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: topic.title))
        .alert(topic.title, isPresented: $isPresented) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text(verbatim: topic.message)
        }
    }
}
