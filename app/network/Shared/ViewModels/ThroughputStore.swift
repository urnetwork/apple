//
//  ThroughputStore.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * Throughput deltas for one route over one sample interval
 */
struct ThroughputSample {
    let egressByteCount: Int64
    let ingressByteCount: Int64
    let egressPacketCount: Int64
    let ingressPacketCount: Int64

    static let zero = ThroughputSample(
        egressByteCount: 0,
        ingressByteCount: 0,
        egressPacketCount: 0,
        ingressPacketCount: 0
    )

    init(
        egressByteCount: Int64,
        ingressByteCount: Int64,
        egressPacketCount: Int64,
        ingressPacketCount: Int64
    ) {
        self.egressByteCount = egressByteCount
        self.ingressByteCount = ingressByteCount
        self.egressPacketCount = egressPacketCount
        self.ingressPacketCount = ingressPacketCount
    }

    init(_ sample: SdkThroughputSample?) {
        self.egressByteCount = sample?.egressByteCount ?? 0
        self.ingressByteCount = sample?.ingressByteCount ?? 0
        self.egressPacketCount = sample?.egressPacketCount ?? 0
        self.ingressPacketCount = sample?.ingressPacketCount ?? 0
    }
}

/**
 * One throughput sample, split by route
 */
struct ThroughputPoint: Identifiable {
    /**
     * sample end time, unix seconds
     */
    let time: TimeInterval
    let remote: ThroughputSample
    let local: ThroughputSample
    let block: ThroughputSample

    var id: TimeInterval { time }

    init(time: TimeInterval, remote: ThroughputSample, local: ThroughputSample, block: ThroughputSample) {
        self.time = time
        self.remote = remote
        self.local = local
        self.block = block
    }

    init(_ point: SdkThroughputPoint) {
        self.time = TimeInterval(point.time) / 1000.0
        self.remote = ThroughputSample(point.remote)
        self.local = ThroughputSample(point.local)
        self.block = ThroughputSample(point.block)
    }
}

/**
 * One transport's slice of the window's remote traffic, ready to render as a
 * segment of the transport bar plus its legend entry. A mirror of the SDK's
 * `TransportShare`: every render value (share, cumulative boundary, whole
 * percent, used, enabled) is computed by the SDK view controller so the math
 * is shared and tested once for every platform.
 */
struct TransportShare: Equatable, Identifiable {
    let transportType: TransportType
    let egressByteCount: Int64
    let ingressByteCount: Int64
    /**
     * fraction of the window's remote bytes, 0..1; 0 while idle
     */
    let share: Double
    /**
     * the right edge of the segment as a fraction of the bar width: the
     * cumulative share through this transport in stable order. Rendering every
     * segment from its neighbours' boundaries tiles exactly 100% of the bar
     */
    let boundary: Double
    /**
     * whole percent for the legend; the used percents sum to exactly 100.
     * A sliver can round to 0 while still used
     */
    let percent: Int
    /**
     * carried traffic in the window: draws a segment and a legend entry
     */
    let used: Bool
    /**
     * enabled by the transport settings; unused footer entry when idle
     */
    let enabled: Bool

    var id: TransportType { transportType }

    var byteCount: Int64 {
        egressByteCount + ingressByteCount
    }

    init(
        transportType: TransportType,
        egressByteCount: Int64 = 0,
        ingressByteCount: Int64 = 0,
        share: Double = 0,
        boundary: Double = 0,
        percent: Int = 0,
        used: Bool = false,
        enabled: Bool = false
    ) {
        self.transportType = transportType
        self.egressByteCount = egressByteCount
        self.ingressByteCount = ingressByteCount
        self.share = share
        self.boundary = boundary
        self.percent = percent
        self.used = used
        self.enabled = enabled
    }

    /**
     * nil for a transport type this app does not know (a newer sdk vocabulary)
     */
    init?(_ share: SdkTransportShare) {
        guard let transportType = TransportType(rawValue: share.transportType) else {
            return nil
        }
        self.transportType = transportType
        self.egressByteCount = share.egressByteCount
        self.ingressByteCount = share.ingressByteCount
        self.share = share.share
        self.boundary = share.boundary
        self.percent = share.percent
        self.used = share.used
        self.enabled = share.enabled
    }
}

/**
 * The window's remote traffic partitioned by the transport that carried it,
 * in the SDK's stable order with every transport present. Follows the same
 * window as the throughput points, so it drains to inactive as traffic ages
 * out. A mirror of the SDK's `TransportDistribution`.
 */
struct TransportDistribution: Equatable {
    /**
     * stable order: h3, h1, dns, dnspump, p2p, unknown
     */
    let shares: [TransportShare]
    let byteCount: Int64
    /**
     * whether any transport carried traffic in the window
     */
    let active: Bool

    static let empty = TransportDistribution(shares: [], byteCount: 0, active: false)

    init(shares: [TransportShare], byteCount: Int64, active: Bool) {
        self.shares = shares
        self.byteCount = byteCount
        self.active = active
    }

    init(_ distribution: SdkTransportDistribution?) {
        guard let distribution else {
            self = .empty
            return
        }
        var shares: [TransportShare] = []
        if let list = distribution.shares {
            shares.reserveCapacity(list.len())
            for i in 0..<list.len() {
                if let item = list.get(i), let share = TransportShare(item) {
                    shares.append(share)
                }
            }
        }
        self.shares = shares
        self.byteCount = distribution.byteCount
        self.active = distribution.active
    }

    /**
     * the segment boundaries in stable order, the vector the bar animates
     */
    var boundaries: AnimatableVector {
        AnimatableVector(values: shares.map { $0.boundary })
    }

    /**
     * the transports with traffic in the window, stable order
     */
    var used: [TransportShare] {
        shares.filter { $0.used }
    }

    /**
     * the enabled transports without traffic in the window, stable order
     */
    var unused: [TransportShare] {
        shares.filter { $0.enabled && !$0.used }
    }
}

enum ThroughputRoute {
    case remote
    case local
    case block

    func sample(for point: ThroughputPoint) -> ThroughputSample {
        switch self {
        case .remote: return point.remote
        case .local: return point.local
        case .block: return point.block
        }
    }
}

private class ThroughputListener: NSObject, SdkThroughputListenerProtocol {
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func throughputChanged() {
        callback()
    }
}

/**
 * Wraps the SDK contract view controller and publishes the live
 * client and provider throughput series
 */
@MainActor
class ThroughputStore: ObservableObject {

    @Published private(set) var clientPoints: [ThroughputPoint] = []
    @Published private(set) var providerPoints: [ThroughputPoint] = []
    /**
     * the remote traffic of the window partitioned by transport, ready to
     * render (see `TransportDistribution`)
     */
    @Published private(set) var clientTransportDistribution: TransportDistribution = .empty
    @Published private(set) var providerTransportDistribution: TransportDistribution = .empty
    /**
     * false when the device has no provider (providing disabled)
     */
    @Published private(set) var hasProviderStats: Bool = false
    @Published private(set) var windowDuration: TimeInterval = 60

    private var device: SdkDeviceRemote?
    private var contractViewController: SdkContractViewController?
    private var throughputListenerSub: SdkSubProtocol?

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        guard let contractViewController = device.openContractViewController() else {
            return
        }
        self.contractViewController = contractViewController
        self.windowDuration = TimeInterval(contractViewController.getWindowDurationSeconds())

        self.throughputListenerSub = contractViewController.add(ThroughputListener { [weak self] in
            DispatchQueue.main.async {
                self?.update()
            }
        })

        update()
    }

    func reset() {
        throughputListenerSub?.close()
        throughputListenerSub = nil
        if let contractViewController {
            if let device {
                device.close(contractViewController)
            } else {
                contractViewController.close()
            }
        }
        contractViewController = nil
        device = nil

        clientPoints = []
        providerPoints = []
        clientTransportDistribution = .empty
        providerTransportDistribution = .empty
        hasProviderStats = false
    }

    private func update() {
        guard let contractViewController = self.contractViewController else {
            return
        }
        clientPoints = Self.mapPoints(contractViewController.getThroughputPoints())
        providerPoints = Self.mapPoints(contractViewController.getProviderThroughputPoints())
        // the distribution is inactive while the window is idle; only publish a
        // real change so an idle tick doesn't retrigger the bar
        let clientTransportDistribution = TransportDistribution(contractViewController.getTransportDistribution())
        if clientTransportDistribution != self.clientTransportDistribution {
            self.clientTransportDistribution = clientTransportDistribution
        }
        let providerTransportDistribution = TransportDistribution(contractViewController.getProviderTransportDistribution())
        if providerTransportDistribution != self.providerTransportDistribution {
            self.providerTransportDistribution = providerTransportDistribution
        }
        hasProviderStats = contractViewController.getProviderPacketStats() != nil
    }

    private static func mapPoints(_ list: SdkThroughputPointList?) -> [ThroughputPoint] {
        guard let list = list else {
            return []
        }
        var points: [ThroughputPoint] = []
        points.reserveCapacity(list.len())
        for i in 0..<list.len() {
            if let point = list.get(i) {
                points.append(ThroughputPoint(point))
            }
        }
        return points
    }
}
