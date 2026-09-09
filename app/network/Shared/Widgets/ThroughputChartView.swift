//
//  ThroughputChartView.swift
//  URnetwork
//
//  Compiled into the app and the widget extension: the app's Account >
//  Widgets screen draws the dashboard chart with this very view.
//
//  A static version of the app's TransferChart for one route: bytes (green,
//  filled) and packets (pink, a line) sent above the axis and received
//  below, each pair on its own scale, Catmull-Rom smoothed. The app draws
//  one point per second over a 60 s window; the widget draws one bucket per
//  minute over the last hour, because that is the cadence a Home Screen
//  widget can honestly show.
//

import SwiftUI
import WidgetKit

struct ThroughputChartView: View {

    struct Point {
        let start: Int64
        let egress: Int64
        let ingress: Int64
        var egressPackets: Int64 = 0
        var ingressPackets: Int64 = 0
    }

    let title: LocalizedStringKey
    /// The byte series color; packets are always drawn in the app's pink.
    let color: Color
    /// Oldest first; missing buckets are zero.
    let points: [Point]
    let bucketSeconds: Int64
    let now: Date
    /// Shown instead of a peak rate when the series is expected to be flat.
    let placeholder: LocalizedStringKey?

    private static let labelBand: CGFloat = 14
    private static let windowBuckets = WidgetThroughputAccumulator.bucketCount
    /// Floor for the byte scale so an idle chart is flat rather than noisy.
    private static let minimumScale: Int64 = 64 * 1024
    /// Floor for the packet scale: the app's 8 packets/s over one bucket.
    private static let minimumPacketScale: Int64 = 8 * WidgetThroughputAccumulator.bucketSeconds
    private static let packetColor = WidgetTheme.packetSeries

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .widgetAccentable()
                Spacer()
                if placeholder == nil || peak > 0 || peakPackets > 0 {
                    // the two peaks in their series colors, as the app labels
                    // its chart: bytes in green, packets in pink
                    HStack(spacing: 4) {
                        Text(verbatim: peakRate)
                            .foregroundStyle(color)
                        Text(verbatim: "·")
                            .foregroundStyle(WidgetTheme.textMuted)
                        Text(verbatim: peakPacketRate)
                            .foregroundStyle(Self.packetColor)
                        Text("peak")
                            .foregroundStyle(WidgetTheme.textMuted)
                    }
                    .font(WidgetTheme.label)
                }
            }
            .frame(height: Self.labelBand)
            if let placeholder, peak == 0, peakPackets == 0 {
                // the series is expected to be flat: say why instead of drawing it
                Text(placeholder)
                    .font(WidgetTheme.label)
                    .foregroundStyle(WidgetTheme.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    draw(&context, size: size)
                }
            }
        }
    }

    private var window: TimeInterval {
        TimeInterval(bucketSeconds * Int64(Self.windowBuckets))
    }

    private var plot: Plot {
        Self.plot(points: points, bucketSeconds: bucketSeconds, now: now)
    }

    private var peak: Int64 {
        plot.peak
    }

    private var peakPackets: Int64 {
        plot.peakPackets
    }

    /// Bytes per bucket as a rate, formatted like the app's chart labels.
    private var peakRate: String {
        formatByteRate(peak / max(1, bucketSeconds))
    }

    /// Packets per bucket as a rate, formatted like the app's chart labels.
    private var peakPacketRate: String {
        formatPacketRate(peakPackets / max(1, bucketSeconds))
    }

    /// What the chart plots, computed apart from the drawing.
    ///
    /// `draw` runs inside a `Canvas` closure, so nothing can observe what it
    /// decided. Every judgement that can be wrong -- which buckets fall in
    /// the window, and what the curve is scaled against -- lives here so it
    /// can be asserted directly.
    struct Plot: Equatable {
        /// Bucket start times, oldest first, one per bucket across the whole
        /// window whether or not the snapshot carries that bucket.
        var bucketStarts: [Int64]
        /// The largest byte and packet values the scale is taken from.
        var peak: Int64
        var peakPackets: Int64
    }

    static func plot(points: [Point], bucketSeconds: Int64, now: Date) -> Plot {
        let window = TimeInterval(bucketSeconds * Int64(windowBuckets))
        let nowSeconds = now.timeIntervalSince1970
        let windowStart = nowSeconds - window
        var starts: [Int64] = []
        var bucket = (Int64(windowStart) / bucketSeconds) * bucketSeconds
        // up to the last COMPLETE bucket: a bucket's traffic is only known
        // once the minute has elapsed, and the one in progress holds a
        // fraction of its eventual total. Drawn at full weight -- and then
        // held flat to the right edge -- it dived the end of the curve toward
        // zero for reasons that had nothing to do with the network
        while bucket + bucketSeconds <= Int64(nowSeconds) {
            starts.append(bucket)
            bucket += bucketSeconds
        }
        // the scale comes only from what is on screen. The accumulator
        // records a bucket only for a minute that carried traffic, so its 60
        // buckets can span many hours -- and a burst from outside this window
        // used to set the scale for a curve it was not part of, squashing
        // real recent traffic flat onto the axis and freezing the peak label
        // on a rate from hours ago
        let drawn = Set(starts)
        let visible = points.filter { drawn.contains($0.start) }
        return Plot(
            bucketStarts: starts,
            peak: visible.map { max($0.egress, $0.ingress) }.max() ?? 0,
            peakPackets: visible.map { max($0.egressPackets, $0.ingressPackets) }.max() ?? 0
        )
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let centerY = size.height / 2
        let plotHalf = max(1, centerY - 1)
        let plot = self.plot
        // each series pair on its own scale: the peak of either reaches the
        // plot edge, so both are readable whatever their ratio
        let scale = Double(max(plot.peak, Self.minimumScale))
        let packetScale = Double(max(plot.peakPackets, Self.minimumPacketScale))
        let nowSeconds = now.timeIntervalSince1970

        // one sample per bucket across the whole window, zero where nothing
        // was recorded, so the spline is evenly spaced and reaches both edges
        var byStart: [Int64: Point] = [:]
        for point in points {
            byStart[point.start] = point
        }
        var egress: [CGPoint] = []
        var ingress: [CGPoint] = []
        var egressPackets: [CGPoint] = []
        var ingressPackets: [CGPoint] = []
        func x(_ time: TimeInterval) -> CGFloat {
            size.width * CGFloat(max(0, min(1, 1 - (nowSeconds - time) / window)))
        }
        func offset(_ value: Int64, _ scale: Double) -> CGFloat {
            plotHalf * CGFloat(min(1, Double(value) / scale))
        }
        for bucket in plot.bucketStarts {
            let point = byStart[bucket]
            // plot at the bucket's end: the bucket's traffic is known once it
            // has elapsed
            let time = TimeInterval(bucket + bucketSeconds)
            let px = x(time)
            egress.append(CGPoint(x: px, y: centerY - offset(point?.egress ?? 0, scale)))
            ingress.append(CGPoint(x: px, y: centerY + offset(point?.ingress ?? 0, scale)))
            egressPackets.append(CGPoint(x: px, y: centerY - offset(point?.egressPackets ?? 0, packetScale)))
            ingressPackets.append(CGPoint(x: px, y: centerY + offset(point?.ingressPackets ?? 0, packetScale)))
        }
        func holdToEdge(_ series: inout [CGPoint]) {
            if let last = series.last, last.x < size.width {
                series.append(CGPoint(x: size.width, y: last.y))
            }
        }
        holdToEdge(&egress)
        holdToEdge(&ingress)
        holdToEdge(&egressPackets)
        holdToEdge(&ingressPackets)

        let topHalf = CGRect(x: 0, y: 0, width: size.width, height: centerY)
        let bottomHalf = CGRect(x: 0, y: centerY, width: size.width, height: size.height - centerY)
        // bytes filled under the curve, packets as a thinner line over them,
        // as the app's TransferChart layers them
        drawSeries(&context, points: egress, clip: topHalf, color: color, lineWidth: 1.5, fillTo: centerY)
        drawSeries(&context, points: ingress, clip: bottomHalf, color: color, lineWidth: 1.5, fillTo: centerY)
        drawSeries(&context, points: egressPackets, clip: topHalf, color: Self.packetColor, lineWidth: 1, fillTo: nil)
        drawSeries(&context, points: ingressPackets, clip: bottomHalf, color: Self.packetColor, lineWidth: 1, fillTo: nil)

        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: centerY))
        axis.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(axis, with: .color(WidgetTheme.axis), lineWidth: 1)
    }

    private func drawSeries(
        _ context: inout GraphicsContext,
        points: [CGPoint],
        clip: CGRect,
        color: Color,
        lineWidth: CGFloat,
        fillTo axisY: CGFloat?
    ) {
        guard let first = points.first, let last = points.last else {
            return
        }
        var clipped = context
        clipped.clip(to: Path(clip))
        let line = smoothPath(points)
        if let axisY {
            var area = line
            area.addLine(to: CGPoint(x: last.x, y: axisY))
            area.addLine(to: CGPoint(x: first.x, y: axisY))
            area.closeSubpath()
            clipped.fill(area, with: .color(color.opacity(0.12)))
        }
        clipped.stroke(line, with: .color(color.opacity(0.9)), lineWidth: lineWidth)
    }

    /// Catmull-Rom smoothing with x-clamped control points, as in the app's
    /// TransferChart: the curve can ease in y but never loops back in time.
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else {
            return path
        }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 {
                path.addLine(to: points[1])
            }
            return path
        }
        for i in 1..<points.count {
            let p0 = points[max(i - 2, 0)]
            let p1 = points[i - 1]
            let p2 = points[i]
            let p3 = points[min(i + 1, points.count - 1)]
            var c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            var c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            c1.x = min(max(c1.x, p1.x), p2.x)
            c2.x = min(max(c2.x, p1.x), p2.x)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
