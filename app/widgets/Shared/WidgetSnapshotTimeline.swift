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

    /// What the gallery shows: a connected tunnel with a few providers and an
    /// hour of traffic, so the widget's purpose reads at a glance.
    static func sample(at date: Date) -> SnapshotEntry {
        let now = Int64(date.timeIntervalSince1970)
        let bucketSeconds = WidgetThroughputAccumulator.bucketSeconds
        var buckets: [WidgetThroughputBucket] = []
        for i in 0..<WidgetThroughputAccumulator.bucketCount {
            let start = ((now / bucketSeconds) - Int64(WidgetThroughputAccumulator.bucketCount - 1 - i)) * bucketSeconds
            let phase = Double(i) / 9.0
            let client = Int64(6_000_000 + 5_000_000 * sin(phase) + 2_000_000 * sin(phase * 3.1))
            let provider = Int64(1_500_000 + 1_200_000 * sin(phase * 0.7 + 1))
            buckets.append(WidgetThroughputBucket(
                start: start,
                clientEgress: max(0, client / 4),
                clientIngress: max(0, client),
                providerEgress: max(0, provider),
                providerIngress: max(0, provider / 3)
            ))
        }
        let providers = [
            WidgetProviderSnapshot(
                id: "sample-1", country: "Japan", countryCode: "jp", region: "Tokyo", city: "Tokyo",
                lat: 35.68, lon: 139.69, connectedSinceMillis: (now - 3 * 3600) * 1000, colorHex: "F94144"
            ),
            WidgetProviderSnapshot(
                id: "sample-2", country: "Germany", countryCode: "de", region: "Berlin", city: "Berlin",
                lat: 52.52, lon: 13.40, connectedSinceMillis: (now - 1500) * 1000, colorHex: "663F46"
            ),
            WidgetProviderSnapshot(
                id: "sample-3", country: "Brazil", countryCode: "br", region: "São Paulo", city: "São Paulo",
                lat: -23.55, lon: -46.63, connectedSinceMillis: (now - 240) * 1000, colorHex: "43AA8B"
            ),
        ]
        func contract(_ id: String, _ used: Int64, _ total: Int64, _ rate: Int64, stream: Bool = false) -> WidgetContractSnapshot {
            WidgetContractSnapshot(id: id, usedByteCount: used, totalByteCount: total, bitRate: rate, hasStream: stream)
        }
        let mib: Int64 = 1024 * 1024
        let contracts = [
            WidgetContractPeerSnapshot(
                id: "0199a2b4c6d8e0f2",
                send: [contract("s1", 12 * mib, 32 * mib, 2_400_000), contract("s2", 30 * mib, 32 * mib, 0)],
                receive: [contract("r1", 3 * mib, 64 * mib, 8_100_000, stream: true)],
                sendByteCount: 42 * mib, receiveByteCount: 3 * mib, lastActivityMillis: now * 1000
            ),
            WidgetContractPeerSnapshot(
                id: "44f1a2b4c6d8e0f2",
                send: [contract("s3", 6 * mib, 16 * mib, 600_000)],
                receive: [contract("r2", 15 * mib, 16 * mib, 0), contract("r3", 16 * mib, 16 * mib, 0)],
                sendByteCount: 6 * mib, receiveByteCount: 31 * mib, lastActivityMillis: (now - 20) * 1000
            ),
            WidgetContractPeerSnapshot(
                id: "9c3e5a7b9d1f3a5c",
                send: [],
                receive: [contract("r4", 1 * mib, 32 * mib, 0)],
                sendByteCount: 0, receiveByteCount: 1 * mib, lastActivityMillis: (now - 300) * 1000
            ),
            WidgetContractPeerSnapshot(
                id: "b7d9f1a3c5e7a9b1",
                send: [contract("s4", 8 * mib, 8 * mib, 0), contract("s5", 2 * mib, 8 * mib, 0)],
                receive: [contract("r5", 4 * mib, 8 * mib, 0)],
                sendByteCount: 10 * mib, receiveByteCount: 4 * mib, lastActivityMillis: (now - 900) * 1000
            ),
        ]
        let tunnel = WidgetTunnelSnapshot(
            updatedAt: date,
            tunnelActive: true,
            providing: true,
            location: WidgetLocationSnapshot(
                name: "Japan", countryCode: "jp", city: "", region: "", country: "Japan",
                bestAvailable: false, networkPeer: false, providerCount: 3, colorHex: "F94144"
            ),
            providers: providers,
            throughput: WidgetThroughputSnapshot(bucketSeconds: bucketSeconds, buckets: buckets),
            contracts: contracts
        )
        let balance = WidgetBalanceSnapshot(
            updatedAt: date,
            startBalanceByteCount: 24 * 1024 * 1024 * 1024,
            balanceByteCount: 15 * 1024 * 1024 * 1024,
            openTransferByteCount: 1 * 1024 * 1024 * 1024,
            isPro: false
        )
        return SnapshotEntry(
            date: date, tunnel: tunnel, balance: balance, isOn: true, isConfigured: true, isPreview: true
        )
    }
}
