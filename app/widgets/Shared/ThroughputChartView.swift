//
//  ThroughputChartView.swift
//  URnetworkWidgets
//
//  A static version of the app's TransferChart for one series pair: bytes
//  sent above the axis, bytes received below, Catmull-Rom smoothed, filled
//  to the axis. The app draws one point per second over a 60 s window; the
//  widget draws one bucket per minute over the last hour, because that is
//  the cadence a Home Screen widget can honestly show.
//

import SwiftUI
import WidgetKit

struct ThroughputChartView: View {

    struct Point {
        let start: Int64
        let egress: Int64
        let ingress: Int64
    }

    let title: LocalizedStringKey
    let color: Color
    /// Oldest first; missing buckets are zero.
    let points: [Point]
    let bucketSeconds: Int64
    let now: Date
    /// Shown instead of a peak rate when the series is expected to be flat.
    let placeholder: LocalizedStringKey?

    private static let labelBand: CGFloat = 14
    private static let windowBuckets = WidgetThroughputAccumulator.bucketCount
    /// Floor for the y scale so an idle chart is flat rather than noisy.
    private static let minimumScale: Int64 = 64 * 1024

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(WidgetTheme.caption)
                    .foregroundStyle(WidgetTheme.textMuted)
                    .widgetAccentable()
                Spacer()
                if let placeholder, peak == 0 {
                    Text(placeholder)
                        .font(WidgetTheme.label)
                        .foregroundStyle(WidgetTheme.textFaint)
                } else {
                    Text("\(peakRate) peak")
                        .font(WidgetTheme.label)
                        .foregroundStyle(WidgetTheme.textMuted)
                }
            }
            .frame(height: Self.labelBand)
            Canvas { context, size in
                draw(&context, size: size)
            }
        }
    }

    private var window: TimeInterval {
        TimeInterval(bucketSeconds * Int64(Self.windowBuckets))
    }

    private var peak: Int64 {
        points.map { max($0.egress, $0.ingress) }.max() ?? 0
    }

    /// Bytes per bucket as a rate, formatted like the app's chart labels.
    private var peakRate: String {
        formatByteRate(peak / max(1, bucketSeconds))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let centerY = size.height / 2
        let plotHalf = max(1, centerY - 1)
        let scale = Double(max(peak, Self.minimumScale))
        let nowSeconds = now.timeIntervalSince1970
        let windowStart = nowSeconds - window

        // one sample per bucket across the whole window, zero where nothing
        // was recorded, so the spline is evenly spaced and reaches both edges
        var byStart: [Int64: Point] = [:]
        for point in points {
            byStart[point.start] = point
        }
        var egress: [CGPoint] = []
        var ingress: [CGPoint] = []
        func x(_ time: TimeInterval) -> CGFloat {
            size.width * CGFloat(max(0, min(1, 1 - (nowSeconds - time) / window)))
        }
        func offset(_ value: Int64) -> CGFloat {
            plotHalf * CGFloat(min(1, Double(value) / scale))
        }
        let firstBucket = (Int64(windowStart) / bucketSeconds) * bucketSeconds
        var bucket = firstBucket
        while bucket <= Int64(nowSeconds) {
            let point = byStart[bucket]
            // plot at the bucket's end: the bucket's traffic is known once it
            // has elapsed
            let time = TimeInterval(bucket + bucketSeconds)
            egress.append(CGPoint(x: x(time), y: centerY - offset(point?.egress ?? 0)))
            ingress.append(CGPoint(x: x(time), y: centerY + offset(point?.ingress ?? 0)))
            bucket += bucketSeconds
        }
        if let last = egress.last, last.x < size.width {
            egress.append(CGPoint(x: size.width, y: last.y))
        }
        if let last = ingress.last, last.x < size.width {
            ingress.append(CGPoint(x: size.width, y: last.y))
        }

        let topHalf = CGRect(x: 0, y: 0, width: size.width, height: centerY)
        let bottomHalf = CGRect(x: 0, y: centerY, width: size.width, height: size.height - centerY)
        drawSeries(&context, points: egress, clip: topHalf, fillTo: centerY)
        drawSeries(&context, points: ingress, clip: bottomHalf, fillTo: centerY)

        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: centerY))
        axis.addLine(to: CGPoint(x: size.width, y: centerY))
        context.stroke(axis, with: .color(WidgetTheme.axis), lineWidth: 1)
    }

    private func drawSeries(_ context: inout GraphicsContext, points: [CGPoint], clip: CGRect, fillTo axisY: CGFloat) {
        guard let first = points.first, let last = points.last else {
            return
        }
        var clipped = context
        clipped.clip(to: Path(clip))
        let line = smoothPath(points)
        var area = line
        area.addLine(to: CGPoint(x: last.x, y: axisY))
        area.addLine(to: CGPoint(x: first.x, y: axisY))
        area.closeSubpath()
        clipped.fill(area, with: .color(color.opacity(0.12)))
        clipped.stroke(line, with: .color(color.opacity(0.9)), lineWidth: 1.5)
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
