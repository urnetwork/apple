//
//  TunnelIndicatorTests.swift
//  networkTests
//

import Foundation
import SwiftUI
import Testing
@testable import URnetwork

/**
 * The slow internet tunnel's geometry, depth table and motion (apple/DELAY.md
 * §2, §3), pinned against the design canvas's Tunnel component, the
 * reference implementation: its squares at 24 pt are restated here as the
 * canvas computes them (offset, side and stroke to three decimals).
 */
struct TunnelIndicatorTests {

    private static let canvas24: [(offset: CGFloat, side: CGFloat, stroke: CGFloat, opacity: Double)] = [
        (0, 24, 2.256, 1),
        (4.073, 16.574, 1.354, 0.92),
        (6.879, 11.467, 0.812, 0.84),
        (8.816, 7.945, 0.487, 0.76),
        (10.155, 5.513, 0.292, 0.68),
        (11.083, 3.83, 0.175, 0.6),
    ]

    private static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    @Test func theSquaresMatchTheCanvasAt24Points() {
        let squares = TunnelGeometry.squares(size: 24)
        #expect(squares.count == TunnelGeometry.maxDepth)
        for (square, expected) in zip(squares, Self.canvas24) {
            #expect(Self.near(square.frame.minX, expected.offset), "square \(square.index) left \(square.frame.minX)")
            #expect(Self.near(square.frame.minY, expected.offset), "square \(square.index) top \(square.frame.minY)")
            #expect(Self.near(square.frame.width, expected.side), "square \(square.index) side \(square.frame.width)")
            #expect(Self.near(square.frame.height, expected.side), "square \(square.index) side \(square.frame.height)")
            #expect(Self.near(square.lineWidth, expected.stroke), "square \(square.index) stroke \(square.lineWidth)")
            #expect(abs(square.opacity - expected.opacity) < 1e-9, "square \(square.index) opacity \(square.opacity)")
        }
    }

    // the outer square is inset by half its stroke: its stroke's outer edge
    // is the box, at every size
    @Test func theOuterSquareFitsTheBox() {
        for size in [16, 18, 20, 24, 32, 36, 44] as [CGFloat] {
            let outer = TunnelGeometry.square(0, size: size)
            #expect(Self.near(outer.frame.minX, 0, 1e-9))
            #expect(Self.near(outer.frame.width, size, 1e-9))
            #expect(Self.near(outer.lineWidth, 0.094 * size, 1e-9))
        }
    }

    // each stroke is the one outside it times 0.6, and each stroke's
    // centerline square is the outer one's scaled by 0.7^i about the
    // vanishing point at 55% / 55%
    @Test func eachNestedSquareShrinksAboutTheVanishingPoint() {
        let size: CGFloat = 24
        let v = 0.55 * size
        let squares = TunnelGeometry.squares(size: size)
        let outer = squares[0]
        let outerCenterline = outer.frame.insetBy(dx: outer.lineWidth / 2, dy: outer.lineWidth / 2)
        for square in squares.dropFirst() {
            let previous = squares[square.index - 1]
            #expect(Self.near(square.lineWidth, previous.lineWidth * 0.6, 1e-9))
            let f = pow(0.7, CGFloat(square.index))
            let centerline = square.frame.insetBy(dx: square.lineWidth / 2, dy: square.lineWidth / 2)
            #expect(Self.near(centerline.minX, v + f * (outerCenterline.minX - v), 1e-9))
            #expect(Self.near(centerline.maxX, v + f * (outerCenterline.maxX - v), 1e-9))
            // the anchor it scales about while it fades is the vanishing point
            #expect(Self.near(square.frame.minX + square.anchor.x * square.frame.width, v, 1e-9))
            #expect(Self.near(square.frame.minY + square.anchor.y * square.frame.height, v, 1e-9))
        }
    }

    // the left and top gaps open about 1.65 times the right and bottom ones,
    // the tunnel look, and every gap stays open: no square touches the next
    @Test func theLeftAndTopGapsAreWiderThanTheRightAndBottom() {
        for size in [16, 24, 44] as [CGFloat] {
            let squares = TunnelGeometry.squares(size: size)
            for (outer, inner) in zip(squares, squares.dropFirst()) {
                let near = inner.frame.minX - (outer.frame.minX + outer.lineWidth)
                let far = (outer.frame.maxX - outer.lineWidth) - inner.frame.maxX
                #expect(0 < far, "\(size) pt: squares \(outer.index) and \(inner.index) touch")
                #expect(far < near)
            }
            let first = squares[0]
            let second = squares[1]
            let near = second.frame.minX - (first.frame.minX + first.lineWidth)
            let far = (first.frame.maxX - first.lineWidth) - second.frame.maxX
            #expect(abs(near / far - 1.656) < 0.01, "\(size) pt: ratio \(near / far)")
        }
    }

    @Test func theDepthTableNestsAtEachQuantizedLevel() {
        #expect(TunnelGeometry.depth(quality: 0) == 0)
        #expect(TunnelGeometry.depth(quality: 0.25) == 1)
        #expect(TunnelGeometry.depth(quality: 0.5) == 2)
        #expect(TunnelGeometry.depth(quality: 0.75) == 4)
        #expect(TunnelGeometry.depth(quality: 1) == 6)
        #expect((0...4).map { TunnelGeometry.depth(level: $0) } == [0, 1, 2, 4, 6])
    }

    // another sdk quality step interpolates the table and rounds; any
    // non-zero quality shows a square, and nothing out of range breaks it
    @Test func aQualityBetweenTheStepsInterpolatesAndRounds() {
        #expect(TunnelGeometry.depth(quality: 0.01) == 1)
        #expect(TunnelGeometry.depth(quality: 0.6) == 3)
        #expect(TunnelGeometry.depth(quality: 0.875) == 5)
        #expect(TunnelGeometry.depth(quality: 2) == 6)
        #expect(TunnelGeometry.depth(quality: -1) == 0)
        #expect(TunnelGeometry.depth(quality: .nan) == 0)
    }

    @Test func theLevelFollowsTheWorseDirection() {
        #expect(TransportDelayLevel.level(quality: 0) == 0)
        #expect(TransportDelayLevel.level(quality: 0.25) == 1)
        #expect(TransportDelayLevel.level(quality: 0.75) == 3)
        #expect(TransportDelayLevel.level(quality: 1) == 4)
        // non-zero always shows
        #expect(TransportDelayLevel.level(quality: 0.01) == 1)
        #expect(TransportDelayLevel.level(quality: .infinity) == 0)
        let reading = TransportDelayReading(upQuality: 0.25, downQuality: 0.75)
        #expect(reading.level == 3)
        #expect(TransportDelayReading.normal.level == 0)
    }

    // deeper: the new squares fade in from the outside inward, 420 ms each,
    // started 110 ms apart; 0 to 1 builds the full tunnel in 970 ms
    @Test func aDeeperChangeFadesInOuterToInner() {
        let timings = (0..<6).map { TunnelMotion.timing(index: $0, fromDepth: 0, toDepth: 6) }
        #expect(timings.allSatisfy { $0?.appearing == true && $0?.fadeDuration == 0.42 })
        let delays = timings.compactMap { $0?.delay }
        #expect(delays.count == 6)
        for (index, delay) in delays.enumerated() {
            #expect(abs(delay - 0.11 * Double(index)) < 1e-9)
        }
        #expect(abs(TunnelMotion.duration(fromDepth: 0, toDepth: 6) - 0.97) < 1e-9)
    }

    // shallower: they fade out from the inside outward, 320 ms each, 90 ms
    // apart; 1 to 0 clears in 770 ms
    @Test func aShallowerChangeFadesOutInnerToOuter() {
        let timings = (0..<6).map { TunnelMotion.timing(index: $0, fromDepth: 6, toDepth: 0) }
        #expect(timings.allSatisfy { $0?.appearing == false && $0?.fadeDuration == 0.32 })
        // the innermost first
        #expect(abs((timings[5]?.delay ?? -1) - 0) < 1e-9)
        #expect(abs((timings[0]?.delay ?? -1) - 0.45) < 1e-9)
        #expect(abs(TunnelMotion.duration(fromDepth: 6, toDepth: 0) - 0.77) < 1e-9)
    }

    // the order counts from the first square that changes, and a square that
    // does not change has no animation
    @Test func theOrderCountsFromTheFirstSquareThatChanges() {
        // 0.5 to 0.75: squares 2 and 3 appear at once and 110 ms later
        #expect(TunnelMotion.timing(index: 1, fromDepth: 2, toDepth: 4) == nil)
        #expect(TunnelMotion.timing(index: 2, fromDepth: 2, toDepth: 4)?.delay == 0)
        #expect(abs((TunnelMotion.timing(index: 3, fromDepth: 2, toDepth: 4)?.delay ?? -1) - 0.11) < 1e-9)
        #expect(TunnelMotion.timing(index: 4, fromDepth: 2, toDepth: 4) == nil)
        // 0.75 to 0.5: square 3 goes first, square 2 90 ms later
        #expect(TunnelMotion.timing(index: 3, fromDepth: 4, toDepth: 2)?.delay == 0)
        #expect(abs((TunnelMotion.timing(index: 2, fromDepth: 4, toDepth: 2)?.delay ?? -1) - 0.09) < 1e-9)
        // a skipped level, 0.25 to 1, builds every square it changes in turn
        let skipped = (1..<6).compactMap { TunnelMotion.timing(index: $0, fromDepth: 1, toDepth: 6)?.delay }
        #expect(skipped.count == 5)
        #expect(abs(skipped.last! - 0.44) < 1e-9)
        #expect(TunnelMotion.timing(index: 0, fromDepth: 1, toDepth: 6) == nil)
        // no change, no motion
        #expect((0..<6).allSatisfy { TunnelMotion.timing(index: $0, fromDepth: 4, toDepth: 4) == nil })
    }

    // on a fade to 0 the pill waits until the last square starts fading
    @Test func thePillFadesAsItsLastSquareStartsFading() {
        for fromDepth in [1, 2, 4, 6] {
            let lastStart = (0..<6).compactMap { TunnelMotion.timing(index: $0, fromDepth: fromDepth, toDepth: 0)?.delay }.max()
            #expect(abs(TunnelMotion.containerExitDelay(fromDepth: fromDepth) - (lastStart ?? -1)) < 1e-9)
        }
        #expect(TunnelMotion.containerExitDelay(fromDepth: 1) == 0)
        #expect(abs(TunnelMotion.containerExitDelay(fromDepth: 6) - 0.45) < 1e-9)
        #expect(TunnelMotion.containerExitDelay(fromDepth: 0) == 0)
    }

    // the longest sequence stays well inside a Live Activity's 2 s cap, the
    // scale settling included
    @Test func theLongestSequenceFitsTheLiveActivityCap() {
        let lastStart = 0.11 * 5
        #expect(lastStart + TunnelMotion.settleInDuration < 2)
        #expect(0.09 * 5 + TunnelMotion.settleOutDuration < 2)
    }
}
