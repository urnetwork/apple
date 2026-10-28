//
//  TunnelIndicator.swift
//  URnetwork
//
//  The slow internet tunnel: nested square outlines that deepen as the
//  transport delay quality worsens (apple/DELAY.md §2, §3). The geometry and
//  the staggered fade are pure values, pinned by TunnelIndicatorTests against
//  the design canvas's Tunnel component, the reference implementation.
//
//  Compiled into the app and the widget extension (the Live Activity). No
//  font or asset dependency.
//

import SwiftUI

/// The tunnel's geometry, relative to the box size S (apple/DELAY.md §2.1).
enum TunnelGeometry {
    /// Six squares fit legibly at 16 pt; a seventh crowds the tight side.
    static let maxDepth = 6
    /// The outer stroke, as a fraction of S.
    static let outerStrokeFraction: CGFloat = 0.094
    /// Each nested stroke is the one outside it times this.
    static let strokeDecay: CGFloat = 0.60
    /// Each nested square is the one outside it scaled by this about the
    /// vanishing point.
    static let shrink: CGFloat = 0.70
    /// The vanishing point, as a fraction of S on both axes: past the
    /// center, so the left and top gaps open wider than the right and bottom.
    static let vanish: CGFloat = 0.55
    /// Each nested square loses this much opacity.
    static let fadePerStep: Double = 0.08

    /// One square of the tunnel.
    struct Square: Equatable {
        let index: Int
        /// The stroke's outer edge: the frame the square draws in. The
        /// outer square's is the whole box.
        let frame: CGRect
        let lineWidth: CGFloat
        /// At full visibility.
        let opacity: Double
        /// The vanishing point within `frame`, as a unit point: what the
        /// square scales about while it fades.
        let anchor: UnitPoint
    }

    static func vanishingPoint(size: CGFloat) -> CGPoint {
        CGPoint(x: vanish * size, y: vanish * size)
    }

    /// Square `index` (0 the outermost) of a tunnel in a box of `size`. The
    /// outer square is inset by half its stroke so it fits the box; each
    /// nested square is the outer one's stroke centerline scaled toward the
    /// vanishing point.
    static func square(_ index: Int, size: CGFloat) -> Square {
        let outerStroke = outerStrokeFraction * size
        let half = outerStroke / 2
        let v = vanish * size
        let f = pow(shrink, CGFloat(index))
        let lineWidth = outerStroke * pow(strokeDecay, CGFloat(index))
        // the stroke centerlines
        let x0 = v + f * (half - v)
        let x1 = v + f * (size - half - v)
        let origin = x0 - lineWidth / 2
        let side = x1 - x0 + lineWidth
        let anchor = 0 < side ? (v - origin) / side : 0.5
        return Square(
            index: index,
            frame: CGRect(x: origin, y: origin, width: side, height: side),
            lineWidth: lineWidth,
            opacity: 1 - fadePerStep * Double(index),
            anchor: UnitPoint(x: anchor, y: anchor)
        )
    }

    static func squares(size: CGFloat) -> [Square] {
        (0..<maxDepth).map { square($0, size: size) }
    }

    /// How many squares a quantized quality shows: 0, 0.25, 0.5, 0.75 and 1
    /// show 0, 1, 2, 4 and 6. A quality between the steps (a different sdk
    /// quality step) interpolates the table and rounds; any non-zero quality
    /// shows at least one.
    static func depth(quality: Double) -> Int {
        guard quality.isFinite, 0 < quality else {
            return 0
        }
        if quality <= 0.25 {
            return 1
        }
        let points: [(quality: Double, depth: Double)] = [(0.25, 1), (0.5, 2), (0.75, 4), (1, 6)]
        for i in 1..<points.count {
            let a = points[i - 1]
            let b = points[i]
            if quality <= b.quality {
                let depth = a.depth + (b.depth - a.depth) * (quality - a.quality) / (b.quality - a.quality)
                return Int(depth.rounded())
            }
        }
        return maxDepth
    }

    /// How many squares a level (0 to 4) shows.
    static func depth(level: Int) -> Int {
        depth(quality: TransportDelayLevel.quality(level: level))
    }
}

/// The tunnel's motion (apple/DELAY.md §3). Squares never move: a change of
/// depth fades the squares that change in or out in place. Deeper, they fade
/// in from the outside inward, 110 ms apart, each settling from 6% larger
/// about the vanishing point; shallower, they fade out from the inside
/// outward, 90 ms apart, easing back toward 6% larger.
enum TunnelMotion {
    static let fadeInDuration: Double = 0.42
    static let fadeInStagger: Double = 0.11
    static let fadeOutDuration: Double = 0.32
    static let fadeOutStagger: Double = 0.09
    /// The settle runs a little longer than the fade, on the canvas's curve.
    static let settleInDuration: Double = 0.56
    static let settleOutDuration: Double = 0.42
    /// A hidden square waits this much larger, nearer the viewer.
    static let hiddenScale: CGFloat = 1.06
    /// How long the pill waits on a fade to 0 from `fromDepth` squares: until
    /// the last square has started fading, 450 ms from the full tunnel and at
    /// once from one square, so it never lingers empty.
    static func containerExitDelay(fromDepth: Int) -> Double {
        Double(max(0, min(fromDepth, TunnelGeometry.maxDepth) - 1)) * fadeOutStagger
    }

    struct Timing: Equatable {
        let appearing: Bool
        /// From the change, by the square's order among those that change.
        let delay: Double
        let fadeDuration: Double
        let settleDuration: Double
    }

    /// The timing of square `index` for a change from `fromDepth` to
    /// `toDepth` squares; nil when the square does not change. The order
    /// counts from the first square that changes, so a skipped level runs
    /// the same staggered build for every square it changes.
    static func timing(index: Int, fromDepth: Int, toDepth: Int) -> Timing? {
        let wasVisible = index < fromDepth
        let visible = index < toDepth
        if wasVisible == visible {
            return nil
        }
        if visible {
            return Timing(
                appearing: true,
                delay: Double(index - fromDepth) * fadeInStagger,
                fadeDuration: fadeInDuration,
                settleDuration: settleInDuration
            )
        }
        return Timing(
            appearing: false,
            delay: Double(fromDepth - 1 - index) * fadeOutStagger,
            fadeDuration: fadeOutDuration,
            settleDuration: settleOutDuration
        )
    }

    /// How long a change takes until its last square is fully faded.
    static func duration(fromDepth: Int, toDepth: Int) -> Double {
        (0..<TunnelGeometry.maxDepth).compactMap { index in
            timing(index: index, fromDepth: fromDepth, toDepth: toDepth).map { $0.delay + $0.fadeDuration }
        }.max() ?? 0
    }
}

/// The tunnel, drawn: all six squares stay in the tree and only their opacity
/// and scale change, since insertion transitions are less dependable in
/// widgets and Live Activities. With Reduce Motion the fades and their
/// stagger stay and the scale goes.
///
/// `fromDepth` is the depth before the change being drawn, which orders the
/// stagger. A Live Activity passes its previous level; in the app,
/// AnimatedTunnelIndicator tracks it.
struct TunnelIndicator: View {
    let depth: Int
    var fromDepth: Int? = nil
    let size: CGFloat
    var color: Color = WidgetTheme.urAmber

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let depth = min(TunnelGeometry.maxDepth, max(0, depth))
        let fromDepth = min(TunnelGeometry.maxDepth, max(0, self.fromDepth ?? depth))
        ZStack(alignment: .topLeading) {
            ForEach(TunnelGeometry.squares(size: size), id: \.index) { square in
                let visible = square.index < depth
                let timing = TunnelMotion.timing(index: square.index, fromDepth: fromDepth, toDepth: depth)
                Rectangle()
                    .strokeBorder(color, style: StrokeStyle(lineWidth: square.lineWidth, lineJoin: .miter))
                    .frame(width: square.frame.width, height: square.frame.height)
                    .scaleEffect(visible || reduceMotion ? 1 : TunnelMotion.hiddenScale, anchor: square.anchor)
                    .animation(timing.map { Self.settle($0) }, value: depth)
                    .opacity(visible ? square.opacity : 0)
                    .animation(timing.map { Self.fade($0) }, value: depth)
                    .offset(x: square.frame.minX, y: square.frame.minY)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    private static func fade(_ timing: TunnelMotion.Timing) -> Animation {
        Animation.easeOut(duration: timing.fadeDuration).delay(timing.delay)
    }

    private static func settle(_ timing: TunnelMotion.Timing) -> Animation {
        Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: timing.settleDuration).delay(timing.delay)
    }
}
