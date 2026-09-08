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
//  Reload policy lives in WidgetRefreshPolicy, which carries the budget
//  arithmetic. Entries do NOT keep the data moving -- they all render the one
//  snapshot this timeline read, so what they advance is the elements that are
//  a function of the entry's own date (the globe's provider durations). The
//  dashboard's chart is anchored to the snapshot's clock rather than the
//  entry's, and its freshness label ticks on its own, so neither depends on
//  the entry cadence. State changes arrive sooner through the reloads the app
//  and the tunnel request, and on demand through the refresh button.
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
            // the interval is needed before the entries: the timeline is
            // sized so its last entry lands on the policy date, rather than
            // running out partway through and holding one render until the
            // reload arrives
            let interval = current.isOn
                ? WidgetRefreshPolicy.refreshIntervalWhileUp
                : WidgetRefreshPolicy.refreshIntervalWhileDown
            var entries: [SnapshotEntry] = []
            for i in 0..<WidgetRefreshPolicy.entryCount(covering: interval) {
                entries.append(current.at(now.addingTimeInterval(Double(i) * WidgetRefreshPolicy.entrySpacing)))
            }
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
