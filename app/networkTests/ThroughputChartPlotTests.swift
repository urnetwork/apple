//
//  ThroughputChartPlotTests.swift
//  networkTests
//
//  What the widget's throughput chart decides to draw.
//
//  `draw` runs inside a Canvas closure, so none of this was observable and
//  none of it had ever been asserted. Both cases below are things a reader
//  of the chart cannot tell are happening: the curve is flattened by a value
//  that is not on screen, and its right-hand end is a bucket that has not
//  finished yet.
//
//  Everything here is expressed in bucket and window multiples rather than in
//  literal seconds, so the assertions keep their meaning if the recorded
//  resolution changes again.
//

import Testing
import Foundation
@testable import URnetwork

struct ThroughputChartPlotTests {

    private typealias Point = ThroughputChartView.Point

    private static let bucketSeconds: Int64 = WidgetThroughputAccumulator.bucketSeconds
    private static let window: Int64 = bucketSeconds * Int64(WidgetThroughputAccumulator.bucketCount)

    /// An arbitrary instant on a bucket boundary, and a `now` part-way into
    /// the bucket that starts there -- so that bucket is in progress.
    private static let bucketStart: Int64 = 1_800_000_000
    private static var now: Date {
        Date(timeIntervalSince1970: TimeInterval(bucketStart) + Double(bucketSeconds) / 2)
    }

    private func plot(_ points: [Point]) -> ThroughputChartView.Plot {
        ThroughputChartView.plot(
            points: points,
            bucketSeconds: ThroughputChartPlotTests.bucketSeconds,
            now: ThroughputChartPlotTests.now
        )
    }

    /// The accumulator records a bucket only for an interval that carried
    /// traffic, so its buckets can span far more time than the window. A burst
    /// from outside the drawn window must not set the scale the visible curve
    /// is drawn against -- if it does, real recent traffic is squashed onto
    /// the axis and the chart reads as flat.
    @Test func theScaleComesOnlyFromWhatIsDrawn() {
        let longAgo = Self.bucketStart - 3 * Self.window
        let recent = Self.bucketStart - 2 * Self.bucketSeconds
        let points = [
            Point(start: longAgo, egress: 10 * 1024 * 1024, ingress: 10 * 1024 * 1024,
                  egressPackets: 40_000, ingressPackets: 40_000),
            Point(start: recent, egress: 100 * 1024, ingress: 100 * 1024,
                  egressPackets: 400, ingressPackets: 400),
        ]
        let plot = self.plot(points)

        // the old burst is genuinely off screen
        #expect(!plot.bucketStarts.contains(longAgo))
        #expect(plot.bucketStarts.contains(recent))
        // ... so it must not be what the curve is measured against
        #expect(plot.peak == 100 * 1024)
        #expect(plot.peakPackets == 400)
    }

    /// A bucket's traffic is only known once it has elapsed -- the chart plots
    /// each point at the bucket's END for exactly that reason. The bucket in
    /// progress holds a fraction of its eventual traffic, so drawing it at
    /// full weight dives the right-hand end of the curve toward zero for
    /// reasons that have nothing to do with the network.
    @Test func theInProgressBucketIsNotPlotted() {
        let plot = self.plot([])
        #expect(plot.bucketStarts.last == Self.bucketStart - Self.bucketSeconds)
        #expect(!plot.bucketStarts.contains(Self.bucketStart))
    }

    /// Nothing is plotted from outside the window on either side.
    @Test func everyPlottedBucketIsInsideTheWindow() {
        let plot = self.plot([])
        let nowSeconds = Self.now.timeIntervalSince1970
        let oldest = try! #require(plot.bucketStarts.first)
        let newest = try! #require(plot.bucketStarts.last)
        #expect(Double(oldest) >= nowSeconds - Double(Self.window) - Double(Self.bucketSeconds))
        #expect(Double(newest + Self.bucketSeconds) <= nowSeconds)
    }

    /// A bucket that has just closed IS plotted -- the fix must not drop real
    /// data to avoid the partial bucket.
    @Test func theMostRecentCompleteBucketIsPlotted() {
        let justClosed = Self.bucketStart - Self.bucketSeconds
        let plot = self.plot([Point(start: justClosed, egress: 5, ingress: 5)])
        #expect(plot.bucketStarts.contains(justClosed))
        #expect(plot.peak == 5)
    }

    /// The drawn window spans the recorded history, so the chart shows what
    /// the accumulator kept -- neither a slice of it nor more than exists.
    @Test func theWindowSpansTheRecordedHistory() {
        let plot = self.plot([])
        #expect(plot.bucketStarts.count == WidgetThroughputAccumulator.bucketCount)
    }

    /// A snapshot written by an older build recorded a minute per bucket; it
    /// must still render, as the hour it was recorded as, rather than being
    /// squeezed into the new window.
    @Test func aLegacyCoarseSnapshotStillRenders() {
        let legacyBucketSeconds: Int64 = 60
        let plot = ThroughputChartView.plot(
            points: [],
            bucketSeconds: legacyBucketSeconds,
            now: Self.now
        )
        let span = Double(plot.bucketStarts.count) * Double(legacyBucketSeconds)
        #expect(3000 <= span)
    }
}
