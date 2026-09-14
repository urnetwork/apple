//
//  ExtenderStatsSectionTests.swift
//  networkTests
//

import Foundation
import SwiftUI
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The extender statistics section (EXTENDER.md O4, O8): when it shows, what
 * its chart is bound to and how the chart labels reads, and the store's
 * mapping of the extender series. The series itself (its sampling, holds and
 * gaps) is the sdk's and is tested there.
 */
struct ExtenderStatsSectionTests {

    // MARK: visibility

    // O8: only with the provider statistics visible (a provide mode other than
    // never, and provider stats reported) and the role running
    @Test func theSectionShowsOnlyWithTheProviderStatisticsAndARunningRole() {
        let visible: Set<String> = ["auto true true", "always true true", "network true true"]
        var combinations = 0
        for mode in ProvideControlMode.allCases {
            for hasProviderStats in [false, true] {
                for extenderRunning in [false, true] {
                    combinations += 1
                    let key = "\(mode.rawValue) \(hasProviderStats) \(extenderRunning)"
                    let shown = extenderStatsSectionVisible(
                        provideControlMode: mode,
                        hasProviderStats: hasProviderStats,
                        extenderRunning: extenderRunning
                    )
                    #expect(shown == visible.contains(key), "\(key)")
                }
            }
        }
        #expect(combinations == 16)
    }

    // MARK: the chart

    @Test func theChartIsTheExtenderSeriesInTheRemoteRoute() {
        let points = [
            ThroughputPoint(
                time: 1_700_000_001,
                remote: ThroughputSample(
                    egressByteCount: 1_200_000,
                    ingressByteCount: 3_400_000,
                    egressPacketCount: 340,
                    ingressPacketCount: 512
                ),
                local: .zero,
                block: .zero
            ),
        ]
        let chart = ExtenderStatsSection.chart(points: points, window: 60)
        #expect(chart.points == points)
        #expect(chart.route == .remote)
        #expect(chart.title == LocalizedStringKey("Extender"))
        #expect(chart.window == 60)
        #expect(chart.height == 128)
        #expect(chart.byteColor == .urLightBlue)
        #expect(chart.packetColor == .urPink)
        #expect(chart.countUnit == .reads)
    }

    @Test func aChartCountsPacketsUnlessToldOtherwise() {
        #expect(TransferChart(points: [], route: .local).countUnit == .packets)
        #expect(TransferChart.CountUnit.packets.formatRate(340) == "340 pkt/s")
        #expect(TransferChart.CountUnit.reads.formatRate(340) == "340 reads/s")
    }

    @Test func readRatesAreCompact() {
        #expect(formatReadRate(340) == "340 reads/s")
        #expect(formatReadRate(0) == "0 reads/s")
        #expect(formatReadRate(999) == "999 reads/s")
        #expect(formatReadRate(1_000) == "1.0k reads/s")
        #expect(formatReadRate(1_234) == "1.2k reads/s")
        #expect(formatReadRate(12_345) == "12k reads/s")
        #expect(formatReadRate(3_400_000) == "3.4M reads/s")
        // the same compact count as the packet label; only the unit differs
        #expect(formatPacketRate(12_345) == "12k pkt/s")
    }

    // MARK: the store

    private func sample(
        egressBytes: Int64,
        ingressBytes: Int64,
        egressReads: Int64,
        ingressReads: Int64
    ) -> SdkThroughputSample {
        let sample = SdkThroughputSample()
        sample.egressByteCount = egressBytes
        sample.ingressByteCount = ingressBytes
        sample.egressPacketCount = egressReads
        sample.ingressPacketCount = ingressReads
        return sample
    }

    // O3: the extender series carries its sample in the remote route, the reads
    // riding in the packet counts; the local and block routes are empty
    @Test @MainActor func theStoreMapsAnExtenderPointList() {
        let first = SdkThroughputPoint()
        first.time = 1_700_000_001_000
        first.remote = sample(egressBytes: 1_200_000, ingressBytes: 3_400_000, egressReads: 340, ingressReads: 512)
        first.local = SdkThroughputSample()
        first.block = SdkThroughputSample()
        let second = SdkThroughputPoint()
        second.time = 1_700_000_002_500
        second.remote = sample(egressBytes: 0, ingressBytes: 900, egressReads: 0, ingressReads: 3)
        second.local = nil
        second.block = nil
        let list = SdkNewThroughputPointList()
        list?.add(first)
        list?.add(second)

        let points = ThroughputStore.mapPoints(list)
        #expect(points == [
            ThroughputPoint(
                time: 1_700_000_001,
                remote: ThroughputSample(
                    egressByteCount: 1_200_000,
                    ingressByteCount: 3_400_000,
                    egressPacketCount: 340,
                    ingressPacketCount: 512
                ),
                local: .zero,
                block: .zero
            ),
            ThroughputPoint(
                time: 1_700_000_002.5,
                remote: ThroughputSample(
                    egressByteCount: 0,
                    ingressByteCount: 900,
                    egressPacketCount: 0,
                    ingressPacketCount: 3
                ),
                local: .zero,
                block: .zero
            ),
        ])
        // the chart reads each point's remote route
        #expect(points.map { ThroughputRoute.remote.sample(for: $0).ingressPacketCount } == [512, 3])
    }

    @Test @MainActor func theStoreMapsAnEmptyExtenderPointListToNoPoints() {
        #expect(ThroughputStore.mapPoints(SdkNewThroughputPointList()).isEmpty)
        #expect(ThroughputStore.mapPoints(nil).isEmpty)
    }

    @Test @MainActor func theStoreStartsAndResetsWithNoExtenderPoints() {
        let store = ThroughputStore()
        #expect(store.extenderPoints.isEmpty)
        store.reset()
        #expect(store.extenderPoints.isEmpty)
    }
}
