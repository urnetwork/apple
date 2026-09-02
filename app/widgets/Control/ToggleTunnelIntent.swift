//
//  ToggleTunnelIntent.swift
//  URnetworkWidgets
//
//  The one intent behind every quick connect surface: the Control Center
//  toggle sets `value` to the requested state before calling perform(); the
//  Home Screen widget's toggle is built with the target state explicitly.
//
//  It runs in the widget extension's process (it never asks for the app), so
//  it must stay SDK-free and quick: it starts or stops the installed tunnel
//  configuration, records the decision for the app, and waits a bounded time
//  for NEVPNStatus to settle so the control re-renders with the right state.
//

import AppIntents

struct ToggleTunnelIntent: SetValueIntent {

    static let title: LocalizedStringResource = "Toggle URnetwork VPN"

    /// Driven by the control and the widget, not offered as a standalone
    /// Shortcuts action: the app's ConnectIntent / DisconnectIntent are the
    /// discoverable pair.
    static let isDiscoverable: Bool = false

    /// Works from a locked Lock Screen without Face ID / Touch ID / passcode,
    /// like the system's own VPN control (product decision, 2026-09-01). The
    /// app's Shortcuts intents keep requiring authentication because they
    /// launch the app.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// The requested state: true = connect.
    @Parameter(title: "Connected")
    var value: Bool

    /// Which surface made the request (`TunnelIntentStore.source*`), kept for
    /// the shared intent record. A parameter rather than a plain property so
    /// it survives the system's intent serialization.
    @Parameter(title: "Source", default: "control")
    var source: String

    init() {}

    init(value: Bool, source: String) {
        self.value = value
        self.source = source
    }

    func perform() async throws -> some IntentResult {
        await TunnelControlSupport.setTunnel(on: value, source: source)
        // the surface that ran this intent is re-rendered by the system when
        // perform() returns; the others are not, and the tunnel extension's
        // own reload requests are best-effort, so re-render them from here
        // (the widget process is a first-class WidgetKit caller)
        WidgetRefresh.reloadAll()
        return .result()
    }
}
