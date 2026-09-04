//
//  WidgetSnapshotSample.swift
//  URnetwork
//
//  The sample the widgets render in the gallery and as their placeholder,
//  and the app renders on the onboarding page (before anyone has connected)
//  and on Account > Widgets until a real snapshot exists: a connected tunnel
//  with a few providers, an hour of bursty client traffic, provide mode
//  Never and a handful of contracts, so the widgets' purpose reads at a
//  glance. One definition, compiled into the
//  app and the widget extension, so the two never drift.
//

import Foundation

enum WidgetSnapshotSample {

    /// A connected tunnel snapshot as of `date`: an hour of client traffic
    /// and provide mode Never (what a fresh install has), so the provider
    /// chart shows its "enable the provider" note as it does on a new device.
    static func tunnel(at date: Date) -> WidgetTunnelSnapshot {
        let now = Int64(date.timeIntervalSince1970)
        let bucketSeconds = WidgetThroughputAccumulator.bucketSeconds
        let count = WidgetThroughputAccumulator.bucketCount
        // an hour of real-looking client traffic: a quiet floor with a
        // handful of sharp bursts of different heights, a long idle stretch,
        // and the biggest burst still under way at the right edge
        let clientBytesPerSecond = burstSeries(count: count, floor: sampleByteFloor, bursts: sampleByteBursts)
            .map { $0 * 1024 }
        let clientPacketsPerSecond = burstSeries(count: count, floor: samplePacketFloor, bursts: samplePacketBursts)
        var buckets: [WidgetThroughputBucket] = []
        for i in 0..<count {
            let start = ((now / bucketSeconds) - Int64(count - 1 - i)) * bucketSeconds
            // the bucket holds a minute of the rate; downloads dominate, with
            // a tenth of the bytes and half the packets going up (requests
            // and acks: fewer bytes, more packets per byte)
            let ingress = clientBytesPerSecond[i] * Double(bucketSeconds)
            let ingressPackets = clientPacketsPerSecond[i] * Double(bucketSeconds)
            buckets.append(WidgetThroughputBucket(
                start: start,
                clientEgress: Int64(ingress * 0.10),
                clientIngress: Int64(ingress),
                providerEgress: 0,
                providerIngress: 0,
                clientEgressPackets: Int64(ingressPackets * 0.50),
                clientIngressPackets: Int64(ingressPackets),
                providerEgressPackets: 0,
                providerIngressPackets: 0
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
            providing: false,
            provideMode: "never",
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

/// One burst of the sample curve: where it sits in the window (0 an hour
/// ago, 1 now), how wide it is, and how far it rises above the floor. The
/// centers sit exactly on sample points of the 60-bucket grid (`k / 59`),
/// so each peak lands in one bucket and the labels read the full heights.
private struct SampleBurst {
    let center: Double
    let width: Double
    let amplitude: Double
}

/// The client byte rate over the window in KiB/s: a 6 KiB/s floor and six
/// bursts, the tallest at the right edge (410 KiB/s at its peak).
/// Shared term for term with the Android sample so both previews draw the
/// same curve.
private let sampleByteFloor: Double = 6
private let sampleByteBursts: [SampleBurst] = [
    SampleBurst(center: 8.0 / 59, width: 0.012, amplitude: 60),
    SampleBurst(center: 15.0 / 59, width: 0.010, amplitude: 330),
    SampleBurst(center: 22.0 / 59, width: 0.012, amplitude: 190),
    SampleBurst(center: 27.0 / 59, width: 0.010, amplitude: 160),
    SampleBurst(center: 47.0 / 59, width: 0.015, amplitude: 45),
    SampleBurst(center: 57.0 / 59, width: 0.012, amplitude: 404),
]

/// The client packet rate in packets/s over the same bursts, with a
/// different height per burst so the two lines stay distinguishable
/// (594 pkt/s at the tallest).
private let samplePacketFloor: Double = 9
private let samplePacketBursts: [SampleBurst] = [
    SampleBurst(center: 8.0 / 59, width: 0.014, amplitude: 110),
    SampleBurst(center: 15.0 / 59, width: 0.011, amplitude: 470),
    SampleBurst(center: 22.0 / 59, width: 0.013, amplitude: 300),
    SampleBurst(center: 27.0 / 59, width: 0.012, amplitude: 260),
    SampleBurst(center: 47.0 / 59, width: 0.016, amplitude: 90),
    SampleBurst(center: 57.0 / 59, width: 0.013, amplitude: 585),
]

/// The curve sampled once per bucket, oldest first, with `t` running from
/// 0 to 1 across the buckets: floor + Σ amplitude · exp(−((t − center) / width)²).
/// Deterministic, so the gallery preview never flickers.
private func burstSeries(count: Int, floor: Double, bursts: [SampleBurst]) -> [Double] {
    (0..<count).map { i in
        let t = Double(i) / Double(max(1, count - 1))
        return bursts.reduce(floor) { value, burst in
            let d = (t - burst.center) / burst.width
            return value + burst.amplitude * exp(-d * d)
        }
    }
}
