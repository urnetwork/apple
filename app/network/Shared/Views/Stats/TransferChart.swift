//
//  TransferChart.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import SwiftUI

/**
 * Live transfer chart for one throughput route.
 *
 * The chart is mirrored around a center horizontal axis: egress traffic is
 * drawn above the line and ingress traffic below it. Byte counts and packet
 * counts are drawn on parallel axes, each normalized to its own window
 * maximum. The egress window maximums are labeled on the top right, with the
 * ingress maximums under them. The latest data is on the right and shifts
 * left as time progresses.
 */
struct TransferChart: View {

    @EnvironmentObject var themeManager: ThemeManager

    let points: [ThroughputPoint]
    let route: ThroughputRoute
    var title: LocalizedStringKey? = nil
    var height: CGFloat = 128
    var window: TimeInterval = 60
    var byteColor: Color = .urGreen
    var packetColor: Color = .urPink
    /// what the count series counts: packets, or reads for the extender
    /// series, whose relay moves byte streams with no packet boundary
    var countUnit: CountUnit = .packets

    // the top-right stats average over the last N buckets (≈ N seconds)
    private let averageBucketCount = 5

    // duration of the smooth transitions: the rightmost value easing to a new
    // bucket, and the axis scale easing to a new maximum
    private let transitionDuration: Double = 0.5

    // the axis scale eases toward a new maximum rather than jumping. tracked in
    // state so the ease can start from wherever the previous transition left off
    @State private var byteScaleTransition: ValueTransition? = nil
    @State private var packetScaleTransition: ValueTransition? = nil

    // bumped by a one-shot waker so the view re-evaluates `animated` (and the
    // TimelineView pauses) once traffic has drained out of the window, even
    // when no further throughput updates arrive to trigger a re-render
    @State private var settleTick: UInt8 = 0

    private struct Entry {
        let time: TimeInterval
        let sample: ThroughputSample
    }

    /**
     * A time-based ease of a scalar value from `from` to `to`.
     */
    private struct ValueTransition {
        let from: Double
        let to: Double
        let startTime: TimeInterval

        func value(at now: TimeInterval, duration: Double) -> Double {
            guard duration > 0 else {
                return to
            }
            let progress = min(max((now - startTime) / duration, 0), 1)
            let eased = 1 - pow(1 - progress, 3)
            return from + (to - from) * eased
        }
    }

    var body: some View {

        let entries = points.map { Entry(time: $0.time, sample: route.sample(for: $0)) }

        // scale to the window peak so the peak curve reaches the plot edge
        let peakEgressBytes = entries.reduce(Int64(0)) { max($0, $1.sample.egressByteCount) }
        let peakIngressBytes = entries.reduce(Int64(0)) { max($0, $1.sample.ingressByteCount) }
        let peakEgressPackets = entries.reduce(Int64(0)) { max($0, $1.sample.egressPacketCount) }
        let peakIngressPackets = entries.reduce(Int64(0)) { max($0, $1.sample.ingressPacketCount) }
        let targetScaleBytes = Double(max(max(peakEgressBytes, peakIngressBytes), 1024))
        let targetScalePackets = Double(max(max(peakEgressPackets, peakIngressPackets), 8))

        // top-right stats are the rolling average over the last N buckets
        let avgEgressBytes = averageOverRecent(entries) { $0.egressByteCount }
        let avgIngressBytes = averageOverRecent(entries) { $0.ingressByteCount }
        let avgEgressPackets = averageOverRecent(entries) { $0.egressPacketCount }
        let avgIngressPackets = averageOverRecent(entries) { $0.ingressPacketCount }

        // the peak byte bucket per direction, whose label slides to track it
        let peakEgress = entries.max(by: { $0.sample.egressByteCount < $1.sample.egressByteCount })
        let peakIngress = entries.max(by: { $0.sample.ingressByteCount < $1.sample.ingressByteCount })

        // Only drive the 20fps redraw when something is actually moving:
        // recent traffic still scrolling through the window, or an axis-scale
        // ease in flight. Otherwise the chart is a static flat line and the
        // TimelineView pauses. This matters most on macOS, where the Connect
        // tab keeps all three charts mounted and visible indefinitely.
        let _ = settleTick
        let clock = Date().timeIntervalSince1970
        let lastActivityTime = entries.last(where: { isActive($0.sample) })?.time
        let hasRecentActivity = lastActivityTime.map { clock - $0 < window } ?? false
        let animated = hasRecentActivity
            || isSettling(byteScaleTransition, asOf: clock)
            || isSettling(packetScaleTransition, asOf: clock)

        ZStack(alignment: .top) {

            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animated)) { timeline in
                let now = timeline.date.timeIntervalSince1970
                // the axis scale eases toward its target maximum
                let scaleBytes = byteScaleTransition?.value(at: now, duration: transitionDuration) ?? targetScaleBytes
                let scalePackets = packetScaleTransition?.value(at: now, duration: transitionDuration) ?? targetScalePackets
                Canvas { context, size in
                    draw(
                        &context,
                        size: size,
                        now: now,
                        entries: entries,
                        scaleBytes: scaleBytes,
                        scalePackets: scalePackets,
                        peakEgress: peakEgress.map { ($0.sample.egressByteCount, $0.time) },
                        peakIngress: peakIngress.map { ($0.sample.ingressByteCount, $0.time) }
                    )
                }
            }

            HStack(alignment: .top) {

                if let title = title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    directionLabel(
                        pointsUp: true,
                        byteValue: avgEgressBytes,
                        packetValue: avgEgressPackets
                    )
                    directionLabel(
                        pointsUp: false,
                        byteValue: avgIngressBytes,
                        packetValue: avgIngressPackets
                    )
                }

            }

        }
        .frame(height: height)
        .onChange(of: targetScaleBytes) { newTarget in
            let now = Date().timeIntervalSince1970
            let current = byteScaleTransition?.value(at: now, duration: transitionDuration) ?? newTarget
            byteScaleTransition = ValueTransition(from: current, to: newTarget, startTime: now)
        }
        .onChange(of: targetScalePackets) { newTarget in
            let now = Date().timeIntervalSince1970
            let current = packetScaleTransition?.value(at: now, duration: transitionDuration) ?? newTarget
            packetScaleTransition = ValueTransition(from: current, to: newTarget, startTime: now)
        }
        .task(id: lastActivityTime) {
            // wake once after the last activity has scrolled fully out of the
            // window so `animated` re-evaluates to false and the timeline
            // pauses, even when no further throughput updates arrive
            guard let lastActivityTime = lastActivityTime else { return }
            let drain = window - (clock - lastActivityTime) + 0.3
            guard drain > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(drain * 1_000_000_000))
            settleTick &+= 1
        }
    }

    /**
     * Linearly interpolates each metric of two samples.
     */
    private func lerpSample(_ a: ThroughputSample, _ b: ThroughputSample, _ t: Double) -> ThroughputSample {
        func lerp(_ x: Int64, _ y: Int64) -> Int64 {
            return x + Int64((Double(y - x) * t).rounded())
        }
        return ThroughputSample(
            egressByteCount: lerp(a.egressByteCount, b.egressByteCount),
            ingressByteCount: lerp(a.ingressByteCount, b.ingressByteCount),
            egressPacketCount: lerp(a.egressPacketCount, b.egressPacketCount),
            ingressPacketCount: lerp(a.ingressPacketCount, b.ingressPacketCount)
        )
    }

    /**
     * The mean of the metric over the last `averageBucketCount` buckets,
     * i.e. the average per second over that window. With a count of 1
     * this is just the latest bucket.
     */
    private func averageOverRecent(_ entries: [Entry], _ selector: (ThroughputSample) -> Int64) -> Int64 {
        let recent = entries.suffix(averageBucketCount)
        guard !recent.isEmpty else {
            return 0
        }
        let sum = recent.reduce(Int64(0)) { $0 + selector($1.sample) }
        return sum / Int64(recent.count)
    }

    /**
     * Whether a sample carries any traffic in any direction.
     */
    private func isActive(_ sample: ThroughputSample) -> Bool {
        return 0 < sample.egressByteCount || 0 < sample.ingressByteCount
            || 0 < sample.egressPacketCount || 0 < sample.ingressPacketCount
    }

    /**
     * Whether an axis-scale ease is still in flight as of `now`.
     */
    private func isSettling(_ transition: ValueTransition?, asOf now: TimeInterval) -> Bool {
        guard let transition = transition else { return false }
        return now - transition.startTime < transitionDuration
    }

    private func directionLabel(pointsUp: Bool, byteValue: Int64, packetValue: Int64) -> some View {
        // the triangle is last so it aligns at the trailing edge across
        // the egress and ingress rows
        HStack(spacing: 5) {
            Text(formatByteRate(byteValue))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(byteColor)
                .opacity(0 < byteValue ? 1 : 0.4)
            Text(countUnit.formatRate(packetValue))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(packetColor)
                .opacity(0 < packetValue ? 1 : 0.4)
            // the arrow lights up in brand white when this direction has
            // activity, like a link light
            DirectionTriangle(
                pointsUp: pointsUp,
                color: (0 < byteValue || 0 < packetValue) ? themeManager.currentTheme.textColor : themeManager.currentTheme.textMutedColor,
                size: 7
            )
        }
    }

    private func draw(
        _ context: inout GraphicsContext,
        size: CGSize,
        now: TimeInterval,
        entries rawEntries: [Entry],
        scaleBytes: Double,
        scalePackets: Double,
        peakEgress: (Int64, TimeInterval)?,
        peakIngress: (Int64, TimeInterval)?
    ) {
        // reserve a band at the top for the average stats and the sliding
        // peak label, and a band at the bottom for the sliding peak label,
        // so the peak labels never overlap the stats or leave the component
        let statsBand: CGFloat = 30
        let peakBand: CGFloat = 13
        let plotTop = statsBand + peakBand
        let plotBottom = size.height - peakBand
        let centerY = (plotTop + plotBottom) / 2
        let plotHalf = max((plotBottom - plotTop) / 2, 8)

        // the center zero axis is drawn last (below) so it always spans the
        // full width and reads consistently as data shifts in
        func drawAxis() {
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: centerY))
            axis.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(axis, with: .color(themeManager.currentTheme.borderBaseColor), lineWidth: 1)
        }

        guard size.width > 0, !rawEntries.isEmpty else {
            drawAxis()
            return
        }

        // ease the newest bucket's value from the previous bucket's value so a
        // changed rightmost value transitions smoothly rather than hopping
        var entries = rawEntries
        let lastIndex = entries.count - 1
        if 1 <= entries.count {
            let lastTime = entries[lastIndex].time
            let prevSample = 2 <= entries.count ? entries[lastIndex - 1].sample : .zero
            let progress = min(max((now - lastTime) / transitionDuration, 0), 1)
            let eased = 1 - pow(1 - progress, 3)
            entries[lastIndex] = Entry(
                time: lastTime,
                sample: lerpSample(prevSample, entries[lastIndex].sample, eased)
            )
        }
        let first = entries[0]
        let last = entries[lastIndex]

        // pad the series so the baseline spans the full width: a flat run of
        // zeros back to the window start on the left (the not-yet-filled
        // region) and a hold of the latest value out to the right edge. the
        // left zeros are laid at the sample cadence rather than as a single
        // far-left point, so the points feeding the spline stay evenly spaced
        // -- a lone real sample sitting after one giant gap back to the window
        // start is what makes the curve loop on itself.
        var padded = entries
        let windowStart = now - window
        if windowStart < first.time {
            let step = 2 <= entries.count ? max(0.2, entries[1].time - first.time) : 1.0
            // walk back from just before the first real sample to the window
            // start, one bucket at a time, so the ramp-in from zero is uniform
            var rampTimes: [TimeInterval] = []
            var t = first.time - step
            while windowStart < t {
                rampTimes.append(t)
                t -= step
            }
            // anchor the baseline exactly at the window start so it reaches the
            // left edge
            rampTimes.append(windowStart)
            padded.insert(contentsOf: rampTimes.reversed().map { Entry(time: $0, sample: .zero) }, at: 0)
        }
        if last.time < now {
            padded.append(Entry(time: now, sample: last.sample))
        }

        func x(_ time: TimeInterval) -> CGFloat {
            size.width * CGFloat(1 - (now - time) / window)
        }
        func offset(_ value: Int64, _ scale: Double) -> CGFloat {
            plotHalf * CGFloat(min(1, Double(value) / max(scale, 1)))
        }

        let egressBytes = padded.map {
            CGPoint(x: x($0.time), y: centerY - offset($0.sample.egressByteCount, scaleBytes))
        }
        let ingressBytes = padded.map {
            CGPoint(x: x($0.time), y: centerY + offset($0.sample.ingressByteCount, scaleBytes))
        }
        let egressPackets = padded.map {
            CGPoint(x: x($0.time), y: centerY - offset($0.sample.egressPacketCount, scalePackets))
        }
        let ingressPackets = padded.map {
            CGPoint(x: x($0.time), y: centerY + offset($0.sample.ingressPacketCount, scalePackets))
        }

        // clip each direction to its half so curve smoothing never
        // crosses the center axis
        let topHalf = CGRect(x: 0, y: 0, width: size.width, height: centerY)
        let bottomHalf = CGRect(x: 0, y: centerY, width: size.width, height: size.height - centerY)

        drawSeries(&context, points: egressBytes, clip: topHalf, color: byteColor, lineWidth: 1.5, fillTo: centerY)
        drawSeries(&context, points: ingressBytes, clip: bottomHalf, color: byteColor, lineWidth: 1.5, fillTo: centerY)
        drawSeries(&context, points: egressPackets, clip: topHalf, color: packetColor, lineWidth: 1, fillTo: nil)
        drawSeries(&context, points: ingressPackets, clip: bottomHalf, color: packetColor, lineWidth: 1, fillTo: nil)

        drawAxis()

        // sliding peak byte-rate labels, above the peak on top and below on bottom.
        // each carries its direction triangle so egress vs ingress reads at a glance
        if let (value, time) = peakEgress {
            drawPeakLabel(&context, size: size, value: value, time: time, now: now, y: statsBand + peakBand / 2, pointsUp: true)
        }
        if let (value, time) = peakIngress {
            drawPeakLabel(&context, size: size, value: value, time: time, now: now, y: size.height - peakBand / 2, pointsUp: false)
        }
    }

    private func drawPeakLabel(
        _ context: inout GraphicsContext,
        size: CGSize,
        value: Int64,
        time: TimeInterval,
        now: TimeInterval,
        y: CGFloat,
        pointsUp: Bool
    ) {
        guard value > 0 else {
            return
        }
        let color = themeManager.currentTheme.textMutedColor
        let resolved = context.resolve(
            Text(formatByteRate(value))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(color)
        )
        let textSize = resolved.measure(in: size)
        let triangleSize: CGFloat = 6
        let gap: CGFloat = 3
        let total = textSize.width + gap + triangleSize

        let rawX = size.width * CGFloat(1 - (now - time) / window)
        // keep the whole label (value + direction triangle) inside the component
        let halfWidth = total / 2 + 2
        let centerX = min(max(rawX, halfWidth), size.width - halfWidth)
        let leftX = centerX - total / 2

        context.draw(resolved, at: CGPoint(x: leftX + textSize.width / 2, y: y), anchor: .center)

        // the direction triangle sits to the right of the value
        let triangleRect = CGRect(
            x: leftX + textSize.width + gap,
            y: y - triangleSize / 2,
            width: triangleSize,
            height: triangleSize
        )
        let triangle = equilateralTrianglePath(in: triangleRect, pointsUp: pointsUp)
        context.fill(triangle, with: .color(color))
        context.stroke(triangle, with: .color(color), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
    }

    private func drawSeries(
        _ context: inout GraphicsContext,
        points: [CGPoint],
        clip: CGRect,
        color: Color,
        lineWidth: CGFloat,
        fillTo: CGFloat?
    ) {
        guard points.count >= 2 else {
            return
        }

        // a copy of the context keeps the clip local to this series
        var layer = context
        layer.clip(to: Path(clip))

        let path = smoothPath(points)

        if let fillTo = fillTo, let first = points.first, let last = points.last {
            var fill = path
            fill.addLine(to: CGPoint(x: last.x, y: fillTo))
            fill.addLine(to: CGPoint(x: first.x, y: fillTo))
            fill.closeSubpath()
            layer.fill(fill, with: .color(color.opacity(0.07)))
        }

        layer.stroke(
            path,
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    /**
     * Catmull-Rom smoothing through the sample points
     */
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
            // the x axis is time and strictly increasing, so keep both control
            // points within the segment's x span. clamping x keeps the cubic
            // monotonic in x -- it can never bow back on itself into a loop when
            // a neighbour is far away (an outlier, or the zero baseline across a
            // gap). y is left free so the curve still eases naturally.
            c1.x = min(max(c1.x, p1.x), p2.x)
            c2.x = min(max(c2.x, p1.x), p2.x)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

}

extension TransferChart {

    /**
     * The unit of a chart's count series and of its rate label. The byte
     * label, the arrows and the opacity rules are the chart's own either way.
     */
    enum CountUnit: Equatable {
        /// "340 pkt/s"
        case packets
        /// "340 reads/s", the extender series (EXTENDER.md O1, O8)
        case reads

        func formatRate(_ countPerSecond: Int64) -> String {
            switch self {
            case .packets:
                return formatPacketRate(countPerSecond)
            case .reads:
                return formatReadRate(countPerSecond)
            }
        }
    }
}

#Preview {

    let now = Date().timeIntervalSince1970
    let points: [ThroughputPoint] = (0..<60).map { i in
        let t = now - TimeInterval(60 - i)
        let egress = Int64(300_000 + 250_000 * sin(Double(i) / 5))
        let ingress = Int64(1_400_000 + 900_000 * sin(Double(i) / 7 + 1))
        let sample = ThroughputSample(
            egressByteCount: max(0, egress),
            ingressByteCount: max(0, ingress),
            egressPacketCount: max(0, egress / 1200),
            ingressPacketCount: max(0, ingress / 1200)
        )
        return ThroughputPoint(time: t, remote: sample, local: .zero, block: .zero)
    }

    return VStack(spacing: 16) {
        TransferChart(points: points, route: .remote, title: "Remote")
        TransferChart(
            points: points,
            route: .remote,
            title: "Blocked",
            byteColor: .urCoral,
            packetColor: .urMutedCoral
        )
    }
    .padding()
    .environmentObject(ThemeManager.shared)
    .background(ThemeManager.shared.currentTheme.backgroundColor)
}
