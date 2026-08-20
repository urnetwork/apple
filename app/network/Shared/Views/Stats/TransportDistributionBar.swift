//
//  TransportDistributionBar.swift
//  URnetwork
//

import SwiftUI

/**
 * The remote traffic of the stats window partitioned by the transport that
 * carried it, as one full-width stacked bar under the transfer chart.
 *
 * Each transport with traffic in the window is a segment proportional to its
 * share, in the SDK's stable transport order, so the bar reads as "this much
 * of the window's transfer went over each carrier". The segments always tile
 * exactly 100% of the width -- also mid-tween -- because the geometry is
 * derived from a single animated vector of the SDK's cumulative boundaries
 * rather than from independently animated widths. Enabled transports that
 * carried nothing in the window are listed in the unused footer instead of
 * drawing a zero-width segment. When the window has no remote traffic at all
 * the bar fades to an empty track and every enabled transport is unused.
 *
 * All the numbers (shares, boundaries, percents, used, enabled) come from the
 * SDK's `TransportDistribution`; this view only draws and animates them.
 * Tapping anywhere on the component opens the transport settings editor.
 */
struct TransportDistributionBar: View {

    @EnvironmentObject var themeManager: ThemeManager

    /**
     * the window's transport distribution from the throughput store
     */
    let distribution: TransportDistribution

    /**
     * opens the transport settings editor
     */
    let action: () -> Void

    // the app's general tween: segment resizing, legend, and the empty fade
    private let tweenDuration: Double = 1.0
    private let barHeight: CGFloat = 8

    // the last non-empty boundaries, held while the window is empty so the bar
    // fades out in place (and back in from its last shape) instead of
    // collapsing to a corner
    @State private var heldBoundaries: AnimatableVector? = nil

    var body: some View {
        let hasTraffic = distribution.active
        // hold the last shape while empty; fall back to the live (all zero)
        // vector before any traffic has been seen
        let displayBoundaries = hasTraffic ? distribution.boundaries : (heldBoundaries ?? distribution.boundaries)
        let usedShares = distribution.used
        let unusedShares = distribution.unused
        let theme = themeManager.currentTheme

        VStack(alignment: .leading, spacing: 6) {

            // title row, styled like the chart title, with a disclosure so the
            // nested tap target reads as its own control inside the card
            HStack(alignment: .center) {
                Text("Transports")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.textMutedColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.textFaintColor)
            }

            // the bar: an empty track with the animated segments on top
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous)
                    .fill(theme.borderBaseColor)

                Color.clear
                    .modifier(
                        TransportSegments(
                            boundaries: displayBoundaries,
                            colors: distribution.shares.map { $0.transportType.color(theme) },
                            separatorColor: theme.tintedBackgroundBase
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous))
                    .opacity(hasTraffic ? 1 : 0)
                    .animation(.easeInOut(duration: tweenDuration), value: displayBoundaries)
                    .animation(.easeInOut(duration: tweenDuration), value: hasTraffic)
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity)

            // legend: the transports with traffic and their share
            if !usedShares.isEmpty {
                legendRow(usedShares)
            }

            // unused footer: enabled transports that carried nothing in the window
            if !unusedShares.isEmpty {
                unusedRow(unusedShares.map { $0.transportType })
            }

        }
        .animation(.easeInOut(duration: tweenDuration), value: usedShares.map { $0.transportType })
        .animation(.easeInOut(duration: tweenDuration), value: unusedShares.map { $0.transportType })
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .onChange(of: distribution) { distribution in
            if distribution.active {
                heldBoundaries = distribution.boundaries
            }
        }
        .onAppear {
            if hasTraffic {
                heldBoundaries = distribution.boundaries
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func legendRow(_ shares: [TransportShare]) -> some View {
        let theme = themeManager.currentTheme
        return FlowRow(horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(shares) { share in
                HStack(spacing: 5) {
                    Circle()
                        .fill(share.transportType.color(theme))
                        .frame(width: 6, height: 6)
                    share.transportType.label
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.textColor)
                    percentLabel(share)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(theme.textMutedColor)
                        .contentTransition(.numericText())
                }
                .transition(.opacity)
            }
        }
        // percent labels roll to their new value with the general tween
        .animation(.easeInOut(duration: tweenDuration), value: shares.map { $0.percent })
    }

    /**
     * The legend percent. The SDK's whole percents sum to exactly 100, so a
     * used sliver can round to 0; label it "<1%" rather than a zero next to a
     * visible segment.
     */
    private func percentLabel(_ share: TransportShare) -> Text {
        if share.used && share.percent == 0 {
            return Text(verbatim: "<") + Text(0.01, format: .percent.precision(.fractionLength(0)))
        }
        return Text(Double(share.percent) / 100, format: .percent.precision(.fractionLength(0)))
    }

    private func unusedRow(_ transports: [TransportType]) -> some View {
        let theme = themeManager.currentTheme
        return FlowRow(horizontalSpacing: 12, verticalSpacing: 4) {
            Text("unused")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.textFaintColor)
            ForEach(transports) { transport in
                HStack(spacing: 5) {
                    // a hollow dot in the transport's color: the color mapping
                    // stays legible even while the transport is idle
                    Circle()
                        .strokeBorder(transport.color(theme).opacity(0.6), lineWidth: 1)
                        .frame(width: 6, height: 6)
                    transport.label
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.textFaintColor)
                }
                .transition(.opacity)
            }
        }
    }
}

/**
 * Draws the stacked segments from one animatable vector of cumulative
 * boundaries (fractions of the width, stable transport order). Because every
 * segment edge is read from the same interpolated vector, the segments tile
 * exactly 100% of the width at every frame of a tween, and a transport
 * entering or leaving grows or shrinks between its neighbours without any
 * neighbour jumping. Hairline separators are drawn between adjacent visible
 * segments and fade with the segment they belong to.
 */
private struct TransportSegments: ViewModifier, Animatable {

    var boundaries: AnimatableVector
    let colors: [Color]
    let separatorColor: Color

    var animatableData: AnimatableVector {
        get { boundaries }
        set { boundaries = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay(
            Canvas { context, size in
                let values = boundaries.values
                guard 0 < size.width, !values.isEmpty else {
                    return
                }
                var start: CGFloat = 0
                var lastVisibleEnd: CGFloat? = nil
                for (i, value) in values.enumerated() {
                    let end = size.width * CGFloat(min(max(value, 0), 1))
                    let width = end - start
                    if 0 < width {
                        let color = i < colors.count ? colors[i] : colors.last ?? .gray
                        context.fill(
                            Path(CGRect(x: start, y: 0, width: width, height: size.height)),
                            with: .color(color)
                        )
                        // a hairline in the card color between this segment and
                        // the previous visible one. Its width eases in with the
                        // narrower of the two so a segment sliding in from zero
                        // width does not pop a full separator
                        if let previousEnd = lastVisibleEnd {
                            let separatorWidth = min(1.0, width / 4)
                            context.fill(
                                Path(CGRect(x: previousEnd - separatorWidth / 2, y: 0, width: separatorWidth, height: size.height)),
                                with: .color(separatorColor)
                            )
                        }
                        lastVisibleEnd = end
                    }
                    start = max(start, end)
                }
            }
        )
    }
}

/**
 * A fixed-length vector of doubles that SwiftUI can interpolate. Vectors of
 * different lengths combine element-wise, treating missing elements as zero.
 */
struct AnimatableVector: VectorArithmetic, Equatable {
    var values: [Double]

    static var zero: AnimatableVector {
        AnimatableVector(values: [])
    }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, +)
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        combine(lhs, rhs, -)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combine(_ lhs: AnimatableVector, _ rhs: AnimatableVector, _ op: (Double, Double) -> Double) -> AnimatableVector {
        let count = max(lhs.values.count, rhs.values.count)
        var values: [Double] = []
        values.reserveCapacity(count)
        for i in 0..<count {
            let a = i < lhs.values.count ? lhs.values[i] : 0
            let b = i < rhs.values.count ? rhs.values[i] : 0
            values.append(op(a, b))
        }
        return AnimatableVector(values: values)
    }
}

/**
 * A left-aligned horizontal flow that wraps items to the next line when they
 * do not fit, for the legend and footer rows on narrow drawers. Every item in
 * a line is aligned on the line's shared text baseline, so the transport
 * names (and the unused label) sit on one common baseline.
 */
struct FlowRow: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 4

    private struct Item {
        let index: Int
        let size: CGSize
        // distance from the item's top to its last text baseline; for items
        // without text this is the bottom edge, which reads as the baseline
        let baseline: CGFloat
    }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
        // deepest ascent above / descent below the shared baseline
        var baseline: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { baseline + descent }
    }

    private func lines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let dimensions = subview.dimensions(in: .unspecified)
            let size = CGSize(width: dimensions.width, height: dimensions.height)
            let baseline = dimensions[VerticalAlignment.lastTextBaseline]
            if !line.items.isEmpty && maxWidth < x + size.width {
                lines.append(line)
                line = Line()
                x = 0
            }
            line.items.append(Item(index: index, size: size, baseline: baseline))
            line.width = x + size.width
            line.baseline = max(line.baseline, baseline)
            line.descent = max(line.descent, size.height - baseline)
            x += size.width + horizontalSpacing
        }
        if !line.items.isEmpty {
            lines.append(line)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = lines(subviews: subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(0, lines.count - 1))
        let width = lines.reduce(0) { max($0, $1.width) }
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + line.baseline - item.baseline),
                    anchor: .topLeading,
                    proposal: .unspecified
                )
                x += item.size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }
}

#Preview {
    // shares as the sdk would compute them for 62% h3, 30% h1, 8% p2p
    let shares: [TransportShare] = [
        TransportShare(transportType: .h3, egressByteCount: 620_000, ingressByteCount: 3_100_000, share: 0.62, boundary: 0.62, percent: 62, used: true, enabled: true),
        TransportShare(transportType: .h1, egressByteCount: 200_000, ingressByteCount: 1_500_000, share: 0.30, boundary: 0.92, percent: 30, used: true, enabled: true),
        TransportShare(transportType: .dns, boundary: 0.92, enabled: true),
        TransportShare(transportType: .dnsPump, boundary: 0.92, enabled: true),
        TransportShare(transportType: .p2p, egressByteCount: 40_000, ingressByteCount: 400_000, share: 0.08, boundary: 1, percent: 8, used: true),
        TransportShare(transportType: .unknown, boundary: 1),
    ]
    let distribution = TransportDistribution(shares: shares, byteCount: 5_860_000, active: true)
    let empty = TransportDistribution(
        shares: [TransportShare(transportType: .h1, enabled: true)],
        byteCount: 0,
        active: false
    )
    return VStack(spacing: 24) {
        TransportDistributionBar(distribution: distribution, action: {})
        TransportDistributionBar(distribution: empty, action: {})
    }
    .padding()
    .environmentObject(ThemeManager.shared)
    .background(ThemeManager.shared.currentTheme.backgroundColor)
}
