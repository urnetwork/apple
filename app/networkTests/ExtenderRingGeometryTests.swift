//
//  ExtenderRingGeometryTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The extender rings of a provider dot (EXTENDER.md K2): how many are drawn,
 * how big they are, and what the filled dot is left with. The connect canvas
 * and the drawer's histogram both draw this, so the geometry is pinned here
 * rather than in either view.
 */
struct ExtenderRingGeometryTests {

    // a comfortable cell: three rings fit with a dot to spare
    private let cell: CGFloat = 32

    @Test func aProviderWithNoExtendersIsAPlainDotFillingTheCell() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: [])
        #expect(geometry.rings.isEmpty)
        #expect(geometry.dotDiameter == cell)
    }

    // K2: the outermost ring's OUTER edge is the cell edge, so a ringed dot
    // never grows into its neighbor. A stroked circle is sized to its
    // centerline, half a stroke inside that.
    @Test func theOutermostRingSitsOnTheCellEdge() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: ["aaaaaa"])
        #expect(geometry.rings.count == 1)
        #expect(geometry.rings[0].diameter == cell - extenderRingStrokeWidth)
        #expect(geometry.strokeWidth == 2)
    }

    // 2pt stroke and 2pt gaps: each ring takes 4pt of radius, so the ring
    // diameters step down by 8 and the dot shrinks 4pt of radius per ring.
    @Test func eachRingTakesFourPointsOfRadius() {
        #expect(extenderRingGeometry(cellSize: cell, colorHexes: ["a"]).dotDiameter == 24)
        #expect(extenderRingGeometry(cellSize: cell, colorHexes: ["a", "b"]).dotDiameter == 16)
        #expect(extenderRingGeometry(cellSize: cell, colorHexes: ["a", "b", "c"]).dotDiameter == 8)

        let three = extenderRingGeometry(cellSize: cell, colorHexes: ["a", "b", "c"])
        #expect(three.rings.map { $0.diameter } == [30, 22, 14])
    }

    // the sdk's order is the drawing order: the first extender is the outer ring
    @Test func ringsTakeTheirColorsInOrderOutermostFirst() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: ["3cdd67", "dd4f3c"])
        #expect(geometry.rings.map { $0.colorHex } == ["3cdd67", "dd4f3c"])
        #expect(geometry.rings.allSatisfy { !$0.dashed })
    }

    // K2: at most three rings, four or more collapse into a dashed third ring
    @Test func fourOrMoreExtendersCollapseIntoADashedThirdRing() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: ["a", "b", "c", "d", "e"])
        #expect(geometry.rings.count == extenderRingMaxCount)
        #expect(geometry.rings.map { $0.dashed } == [false, false, true])
        #expect(geometry.rings.map { $0.colorHex } == ["a", "b", "c"])
        // the footprint is the same as three rings: the dot does not shrink
        // further to make room for extenders that are not drawn
        #expect(geometry.dotDiameter == 8)
    }

    @Test func threeExtendersDrawThreeSolidRings() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: ["a", "b", "c"])
        #expect(geometry.rings.map { $0.dashed } == [false, false, false])
    }

    // The connect grid's cell is the canvas over the grid width — 16pt at the
    // default grid. Three rings would take 24pt of diameter and leave no dot,
    // so the rings that do not fit are dropped and the last drawn one is
    // dashed, exactly as an over-three count is.
    @Test func ringsThatDoNotFitTheCellAreDroppedAndTheLastIsDashed() {
        let geometry = extenderRingGeometry(cellSize: 16, colorHexes: ["a", "b", "c"])
        #expect(geometry.rings.count == 1)
        #expect(geometry.rings[0].dashed)
        #expect(geometry.dotDiameter == 8)
        #expect(extenderRingMinimumDotDiameter <= geometry.dotDiameter)
    }

    @Test func aSingleRingStillFitsTheDefaultGridCell() {
        let geometry = extenderRingGeometry(cellSize: 16, colorHexes: ["a"])
        #expect(geometry.rings.count == 1)
        #expect(!geometry.rings[0].dashed)
        #expect(geometry.dotDiameter == 8)
    }

    @Test func aCellTooSmallForAnyRingKeepsThePlainDot() {
        let geometry = extenderRingGeometry(cellSize: 8, colorHexes: ["a", "b"])
        #expect(geometry.rings.isEmpty)
        #expect(geometry.dotDiameter == 8)
    }

    @Test func anEmptyCellDrawsNothing() {
        let geometry = extenderRingGeometry(cellSize: 0, colorHexes: ["a"])
        #expect(geometry.rings.isEmpty)
        #expect(geometry.dotDiameter == 0)
        #expect(extenderRingGeometry(cellSize: -4, colorHexes: []).dotDiameter == 0)
    }

    // the dot animates in from nothing: the whole glyph scales as one piece,
    // so the rings keep their proportions to the dot at every frame
    @Test func scalingTakesTheRingsAndTheStrokeWithTheDot() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: ["a", "b"])
        let half = geometry.scaled(by: 0.5)
        #expect(half.dotDiameter == geometry.dotDiameter / 2)
        #expect(half.rings.map { $0.diameter } == geometry.rings.map { $0.diameter / 2 })
        #expect(half.strokeWidth == geometry.strokeWidth / 2)
        #expect(half.rings.map { $0.colorHex } == geometry.rings.map { $0.colorHex })
        #expect(geometry.scaled(by: 1) == geometry)
    }

    @Test func scalingToNothingLeavesNothing() {
        let geometry = extenderRingGeometry(cellSize: cell, colorHexes: ["a"]).scaled(by: 0)
        #expect(geometry.dotDiameter == 0)
        #expect(geometry.rings[0].diameter == 0)
    }

    // gomobile binds no string slice, so the sdk carries the per-provider ips
    // and colors as one comma separated string each, in the same order
    @Test func commaSeparatedSdkValuesSplitInOrder() {
        #expect(extenderCommaSeparatedValues("3cdd67,dd4f3c") == ["3cdd67", "dd4f3c"])
        #expect(extenderCommaSeparatedValues("") == [])
        #expect(extenderCommaSeparatedValues(" 3cdd67 , dd4f3c ") == ["3cdd67", "dd4f3c"])
        #expect(extenderCommaSeparatedValues(",,") == [])
    }

    // the color is the sdk's, computed once per address so every app and the
    // ios extension draw the same ring for the same extender (K3)
    @Test func theRingColorIsTheSdkColorOfTheAddress() {
        #expect(SdkGetExtenderColorHex("192.0.2.1") == "3cdd67")
        #expect(SdkGetExtenderColorHex("2001:db8::1") == "dd4f3c")
    }
}
