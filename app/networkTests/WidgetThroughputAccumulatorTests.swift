//
//  WidgetThroughputAccumulatorTests.swift
//  networkTests
//
//  The per-minute history behind the widget's throughput chart.
//
//  The counters it is fed are cumulative for the whole tunnel session, and it
//  stores differences. That makes one case dangerous out of proportion to how
//  often it happens: a counter that reads LOWER than the last sample. Treating
//  that reading as a delta writes an entire session's byte count into a single
//  minute -- a rate orders of magnitude above anything real, which then owns
//  the chart's vertical scale until sixty further traffic-bearing minutes
//  evict it. A tunnel restart does not clear it, because the history is
//  restored on resume.
//

import Testing
import Foundation
@testable import URnetwork

struct WidgetThroughputAccumulatorTests {

    private static let minute: TimeInterval = 60
    private static func at(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + offset)
    }

    /// The first reading has nothing to difference against, so it establishes
    /// the baseline and contributes no traffic.
    @Test func theFirstSampleIsABaselineOnly() {
        var accumulator = WidgetThroughputAccumulator()
        accumulator.recordClient(egress: 5_000, ingress: 9_000, egressPackets: 10, ingressPackets: 20, at: Self.at(0))

        #expect(accumulator.buckets.isEmpty)
    }

    @Test func subsequentSamplesRecordTheDifference() {
        var accumulator = WidgetThroughputAccumulator()
        accumulator.recordClient(egress: 1_000, ingress: 2_000, egressPackets: 1, ingressPackets: 2, at: Self.at(0))
        accumulator.recordClient(egress: 4_000, ingress: 6_000, egressPackets: 4, ingressPackets: 7, at: Self.at(1))

        #expect(accumulator.buckets.count == 1)
        let bucket = accumulator.buckets[0]
        #expect(bucket.clientEgress == 3_000)
        #expect(bucket.clientIngress == 4_000)
        #expect(bucket.clientEgressPackets == 3)
        #expect(bucket.clientIngressPackets == 5)
    }

    /// The one that matters. A reconnect can publish a tick carrying the
    /// retiring client's total on top of the new base, so the next tick reads
    /// lower. That drop must re-baseline, not be banked as a minute's traffic.
    @Test func aCounterThatWentBackwardsDoesNotBecomeAMinuteOfTraffic() {
        var accumulator = WidgetThroughputAccumulator()
        // a long session: five gigabytes moved
        accumulator.recordClient(
            egress: 5_000_000_000, ingress: 5_000_000_000,
            egressPackets: 4_000_000, ingressPackets: 4_000_000, at: Self.at(0)
        )
        // ... then the counter reads lower, as it does after a reconnect
        accumulator.recordClient(
            egress: 1_000, ingress: 1_000,
            egressPackets: 2, ingressPackets: 2, at: Self.at(1)
        )

        #expect(accumulator.buckets.isEmpty)

        // and it carries on from the new baseline
        accumulator.recordClient(
            egress: 4_000, ingress: 5_000,
            egressPackets: 6, ingressPackets: 8, at: Self.at(2)
        )
        #expect(accumulator.buckets.count == 1)
        #expect(accumulator.buckets[0].clientEgress == 3_000)
        #expect(accumulator.buckets[0].clientIngress == 4_000)
    }

    /// An interval that carried no traffic gets no bucket at all, which is why
    /// the buckets can span far more time than the window and why the chart
    /// must scope its scale to the window it draws.
    @Test func idleTimeIsNotRecorded() {
        var accumulator = WidgetThroughputAccumulator()
        accumulator.recordClient(egress: 0, ingress: 0, egressPackets: 0, ingressPackets: 0, at: Self.at(0))
        accumulator.recordClient(egress: 100, ingress: 100, egressPackets: 1, ingressPackets: 1, at: Self.at(1))
        // three hours later, with nothing in between
        accumulator.recordClient(
            egress: 200, ingress: 200, egressPackets: 2, ingressPackets: 2,
            at: Self.at(3 * 3600)
        )

        #expect(accumulator.buckets.count == 2)
        let span = accumulator.buckets[1].start - accumulator.buckets[0].start
        #expect(3 * 3600 - WidgetThroughputAccumulator.bucketSeconds <= span)
    }

    /// The widget records the same shape the app's chart draws, so the two
    /// show the same curve rather than a minute and an hour of the same data.
    @Test func theHistoryIsOneMinuteAtOneSecondResolution() {
        #expect(WidgetThroughputAccumulator.bucketSeconds == 1)
        let window = WidgetThroughputAccumulator.bucketSeconds
            * Int64(WidgetThroughputAccumulator.bucketCount)
        #expect(30 <= window)
        #expect(window <= 60)
    }
}
