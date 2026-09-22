//
//  ExtenderRings.swift
//  URnetwork
//

import SwiftUI

/**
 * The extender rings of a provider dot (connect/EXTENDER.md K2).
 *
 * A provider reached through one or more extenders is drawn as its filled dot
 * with one ring per extender address, in that address's color (K3). The rings
 * grow INWARD: the outermost ring's outer edge sits exactly on the cell edge,
 * so a dot with extenders occupies the same footprint as one without and never
 * bleeds into a neighbor on the connect grid. Each ring is a 2pt stroke with a
 * 2pt gap before the next ring, and a 2pt gap before the filled dot, so the
 * dot's radius shrinks 4pt per ring.
 *
 * At most three rings are drawn. More extenders than rings collapse into the
 * innermost drawn ring, which is dashed to say "and more". The connect canvas
 * draws this geometry into its `Canvas` context at its cell size.
 *
 * The geometry is a pure function of the cell size and the colors, with no
 * view state, so the unit tests exercise it directly.
 */

/// the ring stroke, K2
let extenderRingStrokeWidth: CGFloat = 2

/// the gap between the dot and the first ring, and between successive rings, K2
let extenderRingGap: CGFloat = 2

/// how much of the radius one ring takes: its stroke plus the gap under it
let extenderRingStep: CGFloat = extenderRingStrokeWidth + extenderRingGap

/// the design cap, K2: four or more extenders collapse into a dashed third ring
let extenderRingMaxCount: Int = 3

/**
 * The smallest filled dot a ringed provider keeps.
 *
 * K2 fixes the ring geometry but not what happens when the cell is too small
 * to hold the rings it asks for: at the connect grid's default 16pt cell three
 * rings would consume 24pt of diameter and leave no dot at all (a negative
 * radius). Rings past what the cell can carry are therefore dropped, and the
 * last drawn ring is dashed exactly as an over-three count is — the dot itself
 * is the provider and must stay visible.
 */
let extenderRingMinimumDotDiameter: CGFloat = 4

/// One drawn ring: the diameter of its stroke centerline (what a stroked
/// circle of `strokeWidth` is sized to), its color, and whether it stands in
/// for more extenders than are drawn.
struct ExtenderRing: Equatable {
    let diameter: CGFloat
    let colorHex: String
    let dashed: Bool

    var color: Color {
        Color(hex: colorHex)
    }
}

/// A provider dot with its rings, all in points at one cell size.
struct ExtenderRingGeometry: Equatable {
    /// outermost first
    let rings: [ExtenderRing]
    /// the filled dot inside the rings
    let dotDiameter: CGFloat
    let strokeWidth: CGFloat

    /// the dash pattern of a collapsed ring, in points at this scale
    var dashLength: CGFloat {
        strokeWidth * 1.5
    }

    /// The same assembly at `scale`, for a dot animating in: every diameter and
    /// the stroke scale together so the dot and its rings move as one glyph
    /// rather than the rings snapping into place around a growing dot.
    func scaled(by scale: CGFloat) -> ExtenderRingGeometry {
        guard scale != 1 else {
            return self
        }
        let scale = max(0, scale)
        return ExtenderRingGeometry(
            rings: rings.map {
                ExtenderRing(diameter: $0.diameter * scale, colorHex: $0.colorHex, dashed: $0.dashed)
            },
            dotDiameter: dotDiameter * scale,
            strokeWidth: strokeWidth * scale
        )
    }
}

/**
 * The rings and the filled dot of one provider in a `cellSize` cell.
 *
 * `colorHexes` are the provider's extender colors in the sdk's order (the
 * order of `ProviderGridPoint.extenderIps`); the first is the outermost ring.
 * No extenders is a plain dot filling the cell.
 */
func extenderRingGeometry(cellSize: CGFloat, colorHexes: [String]) -> ExtenderRingGeometry {
    let empty = ExtenderRingGeometry(
        rings: [],
        dotDiameter: max(0, cellSize),
        strokeWidth: extenderRingStrokeWidth
    )
    guard 0 < cellSize, !colorHexes.isEmpty else {
        return empty
    }
    // rings the cell can carry while the dot stays visible; see
    // extenderRingMinimumDotDiameter
    let fits = Int(
        ((cellSize - extenderRingMinimumDotDiameter) / (2 * extenderRingStep))
            .rounded(.down)
    )
    let count = min(colorHexes.count, extenderRingMaxCount, max(0, fits))
    guard 0 < count else {
        return empty
    }
    // the last drawn ring stands in for every extender that did not get one
    let collapsed = count < colorHexes.count
    let rings = (0..<count).map { index in
        ExtenderRing(
            // the outer edge of ring `index` is `index` steps inside the cell
            // edge; a stroked circle is sized to its centerline
            diameter: cellSize - 2 * CGFloat(index) * extenderRingStep - extenderRingStrokeWidth,
            colorHex: colorHexes[index],
            dashed: collapsed && index == count - 1
        )
    }
    return ExtenderRingGeometry(
        rings: rings,
        dotDiameter: cellSize - 2 * CGFloat(count) * extenderRingStep,
        strokeWidth: extenderRingStrokeWidth
    )
}

/// The sdk carries the per-provider extender ips and colors as comma-separated
/// strings in the same order, since gomobile binds no string slice. Empty is a
/// provider with no extender — a direct or p2p route.
func extenderCommaSeparatedValues(_ value: String) -> [String] {
    value
        .split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
