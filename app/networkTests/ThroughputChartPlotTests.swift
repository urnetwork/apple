//
//  ThroughputChartPlotTests.swift
//  networkTests
//
//  What the widget's throughput chart decides to draw.
//
//  `draw` runs inside a Canvas closure, so none of this was observable and
//  none of it had ever been asserted. Both cases below are things a reader
//  of the chart cannot tell are happening: the curve is flattened by a value
//  that is not on screen, and its right-hand end is a minute that has not
//  finished yet.
//

import Testing
import Foundation
@testable import URnetwork

struct ThroughputChartPlotTests {

    private typealias Point = ThroughputChartView.Point

    private static let bucketSeconds: Int64 = 60
    /// An arbitrary fixed instant, 30 seconds into the bucket starting at it.
    private static let bucketStart: Int64 = 1_800_000_000
    private static var now: Date { Date(timeIntervalSince1970: TimeInterval(bucketStart + 30)) }

    private func plot(_ points: [Point], now: Date = ThroughputChartPlotTests.now) -> ThroughputChartView.Plot {
        ThroughputChartView.plot(points: points, bucketSeconds: Self.bucketSeconds, now: now)
    }

    /// The accumulator only appends a bucket for a minute that carried
    /// traffic, so 60 buckets can span many hours. A burst from outside the
    /// drawn hour must not set the scale the visible curve is drawn against
    /// -- if it does, real recent traffic is squashed onto the axis and the
    /// chart reads as flat.
    @Test func theScaleComesOnlyFromWhatIsDrawn() {
        let threeHoursAgo = Self.bucketStart - 3 * 3600
        let points = [
            Point(start: threeHoursAgo, egress: 10 * 1024 * 1024, ingress: 10 * 1024 * 1024,
                  egressPackets: 40_000, ingressPackets: 40_000),
            Point(start: Self.bucketStart - 120, egress: 100 * 1024, ingress: 100 * 1024,
                  egressPackets: 400, ingressPackets: 400),
        ]
        let plot = self.plot(points)

        // the old burst is genuinely off screen
        #expect(!plot.bucketStarts.contains(threeHoursAgo))
        // ... so it must not be what the curve is measured against
        #expect(plot.peak == 100 * 1024)
        #expect(plot.peakPackets == 400)
    }

    /// A bucket's traffic is only known once the minute has elapsed -- the
    /// file says so where it plots each point at the bucket's END. The
    /// in-progress minute holds a fraction of its eventual traffic, so
    /// drawing it at full weight dives the right-hand end of the curve
    /// toward zero for reasons that have nothing to do with the network.
    @Test func theInProgressMinuteIsNotPlotted() {
        let plot = self.plot([])
        // now is 30s into `bucketStart`, so the newest COMPLETE bucket is the
        // one before it
        #expect(plot.bucketStarts.last == Self.bucketStart - Self.bucketSeconds)
    }

    /// Nothing is plotted from outside the window on either side.
    @Test func everyPlottedBucketIsInsideTheWindow() {
        let plot = self.plot([])
        let window = Self.bucketSeconds * 60
        let oldest = try! #require(plot.bucketStarts.first)
        let newest = try! #require(plot.bucketStarts.last)
        #expect(Self.bucketStart - window <= oldest)
        #expect(newest + Self.bucketSeconds <= Self.bucketStart + 30)
    }

    /// A complete bucket that has just closed IS plotted -- the fix must not
    /// drop a whole minute of real data to avoid the partial one.
    @Test func theMostRecentCompleteMinuteIsPlotted() {
        let justClosed = Self.bucketStart - Self.bucketSeconds
        let plot = self.plot([Point(start: justClosed, egress: 5, ingress: 5)])
        #expect(plot.bucketStarts.contains(justClosed))
        #expect(plot.peak == 5)
    }
}
