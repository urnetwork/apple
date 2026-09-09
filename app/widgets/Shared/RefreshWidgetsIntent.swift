//
//  RefreshWidgetsIntent.swift
//  URnetworkWidgets
//
//  The refresh button behind every widget's freshness line.
//
//  A widget cannot make its own data: only the packet tunnel process holds
//  the live counters, and it publishes them to the App Group. So a tap asks
//  the tunnel to publish now, waits a bounded time for that write to land,
//  and then re-renders. With the tunnel down there is nothing to wait for --
//  the writer does not exist -- so the tap re-reads live NEVPNStatus and the
//  last published snapshot instead, which is still worth something: a tunnel
//  brought up from Settings with the app force-quit shows as connected.
//
//  This is the freshness path that matters, because a reload caused by an
//  in-widget intent is not charged against the reload budget that keeps the
//  automatic cadence at tens of minutes (WidgetRefreshPolicy).
//

import AppIntents
import SwiftUI
import WidgetKit

struct RefreshWidgetsIntent: AppIntent {

    static let title: LocalizedStringResource = "Refresh URnetwork widgets"

    /// Not a standalone Shortcuts action: it only means anything as the
    /// button on a widget that is about to re-render.
    static let isDiscoverable: Bool = false

    /// Readable from the Lock Screen without authentication, like the quick
    /// connect toggle it sits beside -- it publishes nothing new, it only
    /// re-reads what the device already shows.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// How long to wait for the tunnel's write. An intent has far longer, but
    /// the user is watching a button: past a few seconds a stale render is
    /// better than a spinner.
    ///
    /// The extension serves this on a `.utility` queue, which is exactly the
    /// work the system defers under Low Power Mode and thermal pressure, so
    /// too tight a bound turns a working refresh into a visible no-op -- the
    /// write lands just after the wait gives up and is not read until the next
    /// timeline reload, up to the policy interval later.
    static let writeTimeout: TimeInterval = 4
    static let pollInterval: TimeInterval = 0.1

    init() {}

    func perform() async throws -> some IntentResult {
        // read the baseline BEFORE signalling, or the wait can miss its own
        // answer when the tunnel writes faster than this task resumes
        let baseline = WidgetSnapshotStore.loadTunnel()?.updatedAt
        WidgetSnapshotRefreshRequest.post()

        if await TunnelControlSupport.currentState().isOn {
            await Self.waitForWrite(after: baseline)
        }

        // the surface that ran this intent is re-rendered by the system when
        // perform() returns; the others are not, and the tunnel extension's
        // own reload requests are best-effort (see ToggleTunnelIntent)
        WidgetRefresh.reloadAll()
        return .result()
    }

    private static func waitForWrite(after baseline: Date?) async {
        let deadline = Date().addingTimeInterval(writeTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard let updatedAt = WidgetSnapshotStore.loadTunnel()?.updatedAt else {
                continue
            }
            if let baseline {
                if baseline < updatedAt {
                    return
                }
            } else {
                return
            }
        }
    }
}

/// The refresh affordance, defined once so the glyph, hit area and
/// accessibility label are the same on every widget.
///
/// `.invalidatableContent()` marks what the tap is about to replace, so the
/// system dims it while the intent runs -- the only in-flight feedback a
/// widget has. The real confirmation is the freshness label itself, which is
/// bound to the snapshot's age rather than to the render, so the button
/// cannot report a success that did not happen.
struct WidgetRefreshButton<Label: View>: View {

    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(intent: RefreshWidgetsIntent()) {
            label()
        }
        .buttonStyle(.plain)
        .invalidatableContent()
        .accessibilityLabel(Text("Refresh"))
    }
}

/// The icon-only form, for headers with no freshness line of their own.
struct WidgetRefreshIcon: View {

    var body: some View {
        WidgetRefreshButton {
            Image(systemName: "arrow.clockwise")
                .font(WidgetTheme.label)
                .foregroundStyle(WidgetTheme.textMuted)
        }
    }
}
