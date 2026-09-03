//
//  WidgetSnapshotSample.swift
//  URnetwork
//
//  The sample the widgets render in the gallery and as their placeholder,
//  and the app renders on the onboarding page (before anyone has connected)
//  and on Account > Widgets until a real snapshot exists: a connected tunnel
//  with a few providers, an hour of traffic and a handful of contracts, so
//  the widgets' purpose reads at a glance. One definition, compiled into the
//  app and the widget extension, so the two never drift.
//

import Foundation

enum WidgetSnapshotSample {

    /// A connected, providing tunnel snapshot as of `date`.
    static func tunnel(at date: Date) -> WidgetTunnelSnapshot {
        let now = Int64(date.timeIntervalSince1970)
        let bucketSeconds = WidgetThroughputAccumulator.bucketSeconds
        let count = WidgetThroughputAccumulator.bucketCount
        // real traffic: a quiet floor with a few bursts that spike and decay
        let clientBursts = burstSeries(
            count: count,
            bursts: [(7, 5_200_000, 0.62), (19, 2_400_000, 0.5), (31, 8_100_000, 0.7), (46, 3_600_000, 0.55), (55, 1_500_000, 0.45)],
            floor: 60_000,
            seed: 17
        )
        let providerBursts = burstSeries(
            count: count,
            bursts: [(11, 1_300_000, 0.6), (38, 900_000, 0.55), (52, 1_900_000, 0.65)],
            floor: 25_000,
            seed: 41
        )
        var buckets: [WidgetThroughputBucket] = []
        for i in 0..<count {
            let start = ((now / bucketSeconds) - Int64(count - 1 - i)) * bucketSeconds
            let client = clientBursts[i]
            let provider = providerBursts[i]
            // packets follow the bytes at a typical ~900 B payload, with the
            // small-packet chatter (acks, DNS, handshakes) that keeps the pink
            // line livelier than the green one
            buckets.append(WidgetThroughputBucket(
                start: start,
                clientEgress: Int64(client * 0.18),
                clientIngress: Int64(client),
                providerEgress: Int64(provider),
                providerIngress: Int64(provider * 0.3),
                clientEgressPackets: Int64(client * 0.18 / 900 + client / 1400),
                clientIngressPackets: Int64(client / 900 + 40),
                providerEgressPackets: Int64(provider / 900 + 25),
                providerIngressPackets: Int64(provider * 0.3 / 900 + provider / 1400)
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
        return WidgetTunnelSnapshot(
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
    }

    /// The balance the gallery shows: a day's start balance, most of it left.
    static func balance(at date: Date) -> WidgetBalanceSnapshot {
        return WidgetBalanceSnapshot(
            updatedAt: date,
            startBalanceByteCount: 24 * 1024 * 1024 * 1024,
            balanceByteCount: 15 * 1024 * 1024 * 1024,
            openTransferByteCount: 1 * 1024 * 1024 * 1024,
            isPro: false
        )
    }
}

/// A bytes-per-bucket series shaped like real traffic: a low, jittery floor
/// with bursts that jump up and tail off (each burst: start bucket, peak
/// bytes, decay per bucket). Deterministic for a given seed so the gallery
/// preview never flickers.
private func burstSeries(count: Int, bursts: [(Int, Double, Double)], floor: Double, seed: UInt64) -> [Double] {
    var state = seed
    func noise() -> Double {
        // a small linear congruential generator: enough for jitter
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) % 1000) / 1000.0
    }
    var series = (0..<count).map { _ in floor * (0.6 + 0.8 * noise()) }
    for (at, peak, decay) in bursts {
        var level = peak
        var i = at
        while i < count && 0.02 * peak < level {
            series[i] += level * (0.85 + 0.3 * noise())
            level *= decay
            i += 1
        }
        // a short ramp into the burst, one bucket before the peak
        if 0 < at { series[at - 1] += peak * 0.3 * noise() }
    }
    return series
}
