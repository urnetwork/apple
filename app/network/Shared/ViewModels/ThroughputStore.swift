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
        hasProviderStats = false
    }

    private func update() {
        guard let contractViewController = self.contractViewController else {
            return
        }
        clientPoints = Self.mapPoints(contractViewController.getThroughputPoints())
        providerPoints = Self.mapPoints(contractViewController.getProviderThroughputPoints())
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
