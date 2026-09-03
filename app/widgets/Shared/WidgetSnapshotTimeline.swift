//
//  WidgetSnapshotTimeline.swift
//  URnetworkWidgets
//
//  One timeline provider for both Home Screen widgets. Every entry renders
//  the same App Group snapshot; the entries differ only in their date so the
//  "updated N min ago" text and the chart's time axis advance between system
//  reloads. The on/off question is answered by the live NEVPNStatus, not by
//  the snapshot, so a toggle flipped from Control Center reads correctly even
//  before the tunnel has written anything.
//
//  Reload policy: WidgetKit budgets reloads (roughly 40-70 a day per widget
//  instance) and the tunnel extension's own reload requests are best-effort,
//  so the timeline asks for a refresh every 20 minutes while the tunnel is
//  up and hourly while it is down. State changes arrive sooner through the
//  reloads the app and the tunnel request.
//

import Foundation
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let tunnel: WidgetTunnelSnapshot
    let balance: WidgetBalanceSnapshot?
    /// Live tunnel state, from NetworkExtension.
    let isOn: Bool
    let isConfigured: Bool
    /// The widget gallery / placeholder rendering: sample data.
    let isPreview: Bool

    /// The tunnel snapshot is meaningful only while the tunnel that wrote it
    /// is still up.
    var showsTunnelData: Bool { isOn && tunnel.tunnelActive }
}

struct SnapshotTimelineProvider: TimelineProvider {

    static let refreshIntervalWhileUp: TimeInterval = 20 * 60
    static let refreshIntervalWhileDown: TimeInterval = 60 * 60
    /// Entries per timeline; each re-renders the same snapshot at a later
    /// date so relative times and the chart axis keep moving.
    static let entrySpacing: TimeInterval = 5 * 60
    static let entryCount = 4

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry.sample(at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        if context.isPreview {
            completion(SnapshotEntry.sample(at: Date()))
            return
        }
        Task {
            completion(await Self.currentEntry(at: Date()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        Task {
            let now = Date()
            let current = await Self.currentEntry(at: now)
            var entries: [SnapshotEntry] = []
            for i in 0..<Self.entryCount {
                entries.append(current.at(now.addingTimeInterval(Double(i) * Self.entrySpacing)))
            }
            let interval = current.isOn ? Self.refreshIntervalWhileUp : Self.refreshIntervalWhileDown
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(interval))))
        }
    }

    static func currentEntry(at date: Date) async -> SnapshotEntry {
        let state = await TunnelControlSupport.currentState()
        let tunnel = WidgetSnapshotStore.loadTunnel() ?? .inactive(at: date)
        let balance = WidgetSnapshotStore.loadBalance()
        return SnapshotEntry(
            date: date,
            tunnel: tunnel,
            balance: balance,
            isOn: state.isOn,
            isConfigured: state.isConfigured,
            isPreview: false
        )
    }
}

extension SnapshotEntry {

    func at(_ date: Date) -> SnapshotEntry {
        SnapshotEntry(
            date: date, tunnel: tunnel, balance: balance,
            isOn: isOn, isConfigured: isConfigured, isPreview: isPreview
        )
    }

    /// What the gallery shows: the shared sample (WidgetSnapshotSample), so
    /// the gallery, the placeholder and the app's onboarding preview agree.
    static func sample(at date: Date) -> SnapshotEntry {
        SnapshotEntry(
            date: date,
            tunnel: WidgetSnapshotSample.tunnel(at: date),
            balance: WidgetSnapshotSample.balance(at: date),
            isOn: true, isConfigured: true, isPreview: true
        )
    }
}
