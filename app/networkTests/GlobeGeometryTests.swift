//
//  GlobeGeometryTests.swift
//  networkTests
//
//  Ported case-for-case from the android GlobeGeometryTest.kt, which is the
//  spec for the orthographic globe projection shared by every platform.
//

import Foundation
import Testing
@testable import URnetwork

struct GlobeGeometryTests {

    // MARK: - projection

    @Test func projectsCardinalPointsAtIdentityRotation() {
        // orthographic at rotation (0, 0), scale 300: the view center (0, 0)
        // lands at (300, 300); (90, 0) is the right limb, (0, 90) the top
        expectPoint(300, 300, GlobeGeometry.project(lon: 0, lat: 0, rotLambda: 0, rotPhi: 0, scale: 300))
        expectPoint(600, 300, GlobeGeometry.project(lon: 90, lat: 0, rotLambda: 0, rotPhi: 0, scale: 300))
        expectPoint(0, 300, GlobeGeometry.project(lon: -90, lat: 0, rotLambda: 0, rotPhi: 0, scale: 300))
        expectPoint(300, 0, GlobeGeometry.project(lon: 0, lat: 90, rotLambda: 0, rotPhi: 0, scale: 300))
        expectPoint(300, 600, GlobeGeometry.project(lon: 0, lat: -90, rotLambda: 0, rotPhi: 0, scale: 300))
    }

    @Test func backHemisphereProjectsToNil() {
        // the antipode of the view center: cos(angle to center) = -1
        #expect(GlobeGeometry.project(lon: 180, lat: 0, rotLambda: 0, rotPhi: 0, scale: 300) == nil)
        #expect(GlobeGeometry.project(lon: 0, lat: 0, rotLambda: 180, rotPhi: 0, scale: 300) == nil)
        expectClose(-1, GlobeGeometry.cosAngleToCenter(lon: 180, lat: 0, rotLambda: 0, rotPhi: 0), 1e-9)
        expectClose(1, GlobeGeometry.cosAngleToCenter(lon: 0, lat: 0, rotLambda: 0, rotPhi: 0), 1e-9)
    }

    @Test func rotationCenteringLandsThePointAtScreenCenter() {
        let rotation = GlobeGeometry.rotationCentering(lon: -122.4, lat: 37.8)
        #expect(rotation.lambda == 122.4)
        #expect(rotation.phi == -37.8)

        expectPoint(
            300,
            300,
            GlobeGeometry.project(
                lon: -122.4, lat: 37.8, rotLambda: rotation.lambda, rotPhi: rotation.phi, scale: 300
            )
        )
        expectClose(
            1,
            GlobeGeometry.cosAngleToCenter(
                lon: -122.4, lat: 37.8, rotLambda: rotation.lambda, rotPhi: rotation.phi
            ),
            1e-9
        )
    }

    @Test func projectClampedMatchesProjectOnTheVisibleHemisphere() {
        let projected = GlobeGeometry.project(lon: 30, lat: 40, rotLambda: 10, rotPhi: -20, scale: 300)
        let clamped = GlobeGeometry.projectClamped(lon: 30, lat: 40, rotLambda: 10, rotPhi: -20, scale: 300)
        #expect(projected != nil)
        expectClose(projected!.x, clamped.x, 1e-9)
        expectClose(projected!.y, clamped.y, 1e-9)
    }

    @Test func projectClampedPutsBackPointsOnTheSilhouetteCircle() {
        // the exact antipode has no azimuthal direction; clamps to (600, 300)
        let antipode = GlobeGeometry.projectClamped(lon: 180, lat: 0, rotLambda: 0, rotPhi: 0, scale: 300)
        expectClose(300, distanceToCenter(antipode), 1e-2)
        expectClose(600, antipode.x, 1e-2)
        expectClose(300, antipode.y, 1e-2)

        // (135, 45) at rotation (0, 0): rotated vector is
        // x = cos(135) cos(45) = -0.5 (behind), y = sin(135) cos(45) = 0.5,
        // z = sin(45) = 0.7071068, so the azimuthal direction (y, z)
        // normalized by sqrt(0.5^2 + 0.7071068^2) = 0.8660254 gives
        // px = 300 + 300 * 0.5 / 0.8660254 = 473.205
        // py = 300 - 300 * 0.7071068 / 0.8660254 = 55.051
        let back = GlobeGeometry.projectClamped(lon: 135, lat: 45, rotLambda: 0, rotPhi: 0, scale: 300)
        expectClose(300, distanceToCenter(back), 1e-2)
        expectClose(473.205, back.x, 1e-2)
        expectClose(55.051, back.y, 1e-2)
    }

    // MARK: - rotation interpolation

    @Test func lerpRotationTakesTheShortWayAroundTheDateLine() {
        // 170 -> -170 is 20 degrees through the date line, not 340 back;
        // the midpoint is the date line itself (180 and -180 are the same)
        let mid = GlobeGeometry.lerpRotation(from: (170, 0), to: (-170, 0), t: 0.5)
        expectClose(180, abs(mid.lambda), 1e-9)
        #expect(mid.phi == 0)
    }

    @Test func lerpRotationTreatsLongitudesModulo360() {
        // 350 is -10: from 10 the short way is backward 20 degrees
        let mid = GlobeGeometry.lerpRotation(from: (10, 0), to: (350, 0), t: 0.5)
        expectClose(0, mid.lambda, 1e-9)

        let end = GlobeGeometry.lerpRotation(from: (10, 0), to: (350, 0), t: 1)
        expectClose(-10, end.lambda, 1e-9)

        let start = GlobeGeometry.lerpRotation(from: (10, 20), to: (350, -40), t: 0)
        #expect(start.lambda == 10)
        #expect(start.phi == 20)
    }

    @Test func lerpRotationInterpolatesAndClampsPhi() {
        let mid = GlobeGeometry.lerpRotation(from: (0, -30), to: (0, 50), t: 0.5)
        expectClose(10, mid.phi, 1e-9)

        // phi never leaves [-90, 90] even for out-of-range endpoints
        let clamped = GlobeGeometry.lerpRotation(from: (0, 80), to: (0, 120), t: 1)
        #expect(clamped.phi == 90)
    }

    @Test func dragSensitivityMatchesTheWebFormula() {
        // Globe.jsx: k = width / projection.scale() / (3 * Math.PI), applied
        // to projection.rotate() which takes degrees. At scale 300:
        // 600 / 300 / (3 * pi) = 2 / (3 * pi) = 0.2122066 degrees per px.
        expectClose(0.2122066, GlobeGeometry.dragDegreesPerVirtualPx(scale: 300), 1e-6)
        // doubling the zoom halves the sensitivity
        expectClose(
            GlobeGeometry.dragDegreesPerVirtualPx(scale: 300) / 2,
            GlobeGeometry.dragDegreesPerVirtualPx(scale: 600),
            1e-12
        )
    }

    // MARK: - graticule

    @Test func graticuleHasTheD3DefaultLineStructure() {
        let lines = GlobeGeometry.graticule()
        #expect(lines.count == 53)

        var meridians = 0
        var parallels = 0
        for line in lines {
            #expect(4 <= line.count)
            #expect(line.count % 2 == 0)
            let constantLon = allEqual(line, offset: 0)
            let constantLat = allEqual(line, offset: 1)
            #expect(constantLon || constantLat, "line is neither a meridian nor a parallel")
            if constantLon {
                meridians += 1
            } else {
                parallels += 1
            }
        }
        // 4 major meridians (-180, -90, 0, 90) + 32 minor (every 10 degrees
        // skipping multiples of 90); the equator + 16 minor parallels
        #expect(meridians == 36)
        #expect(parallels == 17)
    }

    @Test func graticuleStaysInWorldBoundsWithD3Extents() {
        var fullMeridians = 0
        var minorMeridians = 0
        for line in GlobeGeometry.graticule() {
            var minLat: Double = 90
            var maxLat: Double = -90
            for i in stride(from: 0, to: line.count, by: 2) {
                #expect(-180.0001 <= line[i] && line[i] <= 180.0001)
                #expect(-90.0001 <= line[i + 1] && line[i + 1] <= 90.0001)
                minLat = min(minLat, line[i + 1])
                maxLat = max(maxLat, line[i + 1])
            }
            if allEqual(line, offset: 0) {
                // major meridians run pole to pole, minor ones stop at 80
                if 85 < maxLat {
                    fullMeridians += 1
                } else {
                    minorMeridians += 1
                    expectClose(80, maxLat, 1e-3)
                    expectClose(-80, minLat, 1e-3)
                }
            } else {
                // parallels span the full longitude range
                expectClose(-180, line[0], 1e-3)
                expectClose(180, line[line.count - 2], 1e-3)
            }
        }
        #expect(fullMeridians == 4)
        #expect(minorMeridians == 32)
    }

    @Test func graticuleIsSampledEvery2Point5Degrees() {
        for line in GlobeGeometry.graticule() {
            let varyingOffset = allEqual(line, offset: 0) ? 1 : 0
            var maxStep: Double = 0
            for i in stride(from: varyingOffset + 2, to: line.count, by: 2) {
                let step = line[i] - line[i - 2]
                // monotone, never a gap wider than the 2.5 degree precision
                // (the final segment may be shorter where the span is not an
                // exact multiple of the step)
                #expect(-1e-9 <= step)
                #expect(step <= 2.5 + 1e-9)
                maxStep = max(maxStep, step)
            }
            expectClose(2.5, maxStep, 1e-9)
        }
    }

    // MARK: - hit testing

    @Test func nearestWithinPicksTheClosestPointInRange() {
        let points = [
            GlobePoint(100, 100),
            GlobePoint(200, 200),
            GlobePoint(105, 100),
        ]
        #expect(GlobeGeometry.nearestWithin(x: 101, y: 100, points: points, radius: 10) == 0)
        #expect(GlobeGeometry.nearestWithin(x: 104, y: 100, points: points, radius: 10) == 2)
        #expect(GlobeGeometry.nearestWithin(x: 201, y: 199, points: points, radius: 10) == 1)
    }

    @Test func nearestWithinRespectsTheRadius() {
        let points = [GlobePoint(0, 0)]
        #expect(GlobeGeometry.nearestWithin(x: 300, y: 300, points: points, radius: 5) == -1)
        // the radius is inclusive: distance from (3, 4) to (0, 0) is 5
        #expect(GlobeGeometry.nearestWithin(x: 3, y: 4, points: points, radius: 5) == 0)
        #expect(GlobeGeometry.nearestWithin(x: 3, y: 4.01, points: points, radius: 5) == -1)
        #expect(GlobeGeometry.nearestWithin(x: 0, y: 0, points: [], radius: 100) == -1)
    }

    // MARK: - the scroll wheel
    //
    // The globe is a scroll wheel when providers are present: a horizontal
    // drag steps the selection once it passes the hysteresis threshold.

    @Test func aDragShorterThanTheThresholdDoesNotStep() {
        let step = GlobeGeometry.wheelStep(travel: -49, threshold: 50)
        #expect(step.steps == 0)
        // the travel is carried, so continuing the same drag still steps
        expectClose(-49, step.remainingTravel, 1e-9)
    }

    @Test func swipingLeftAdvancesAndSwipingRightGoesBack() {
        #expect(GlobeGeometry.wheelStep(travel: -50, threshold: 50).steps == 1)
        #expect(GlobeGeometry.wheelStep(travel: 50, threshold: 50).steps == -1)
    }

    @Test func aFastDragCrossesSeveralStepsAtOnce() {
        let step = GlobeGeometry.wheelStep(travel: -170, threshold: 50)
        #expect(step.steps == 3)
        // 20px of the drag is left over toward the next step
        expectClose(-20, step.remainingTravel, 1e-9)
    }

    // the hysteresis: after stepping, another full threshold is required, so a
    // finger resting at the boundary cannot flicker between two providers
    @Test func steppingConsumesExactlyOneThresholdOfTravel() {
        var travel: Double = -50
        let first = GlobeGeometry.wheelStep(travel: travel, threshold: 50)
        #expect(first.steps == 1)
        expectClose(0, first.remainingTravel, 1e-9)

        // jitter back and forth around the boundary must not step again
        travel = first.remainingTravel
        for jitter in [-20.0, 15.0, -18.0, 12.0] {
            travel += jitter
            let step = GlobeGeometry.wheelStep(travel: travel, threshold: 50)
            #expect(step.steps == 0)
            travel = step.remainingTravel
        }
    }

    @Test func aNonPositiveThresholdNeverSteps() {
        #expect(GlobeGeometry.wheelStep(travel: -1000, threshold: 0).steps == 0)
    }

    // longitude is cyclic, so the wheel wraps at both ends — stepping east past
    // the last provider lands on the westernmost, the shortest way round
    @Test func theWheelWrapsAtBothEnds() {
        #expect(GlobeGeometry.wrapIndex(index: 2, steps: 1, count: 3) == 0)
        #expect(GlobeGeometry.wrapIndex(index: 0, steps: -1, count: 3) == 2)
        #expect(GlobeGeometry.wrapIndex(index: 0, steps: 1, count: 3) == 1)
        // a multi-step drag wraps more than once
        #expect(GlobeGeometry.wrapIndex(index: 0, steps: 7, count: 3) == 1)
        #expect(GlobeGeometry.wrapIndex(index: 0, steps: -7, count: 3) == 2)
    }

    @Test func wrapIndexReportsNoIndexForAnEmptyWheel() {
        #expect(GlobeGeometry.wrapIndex(index: 0, steps: 1, count: 0) == -1)
    }

    // MARK: - fit-center layout
    //
    // The globe scales to the smaller canvas dimension and centers in both, so
    // a wide (non-square) box neither crops nor offsets it.

    @Test func unitFitsTheSmallerDimension() {
        expectClose(1, GlobeGeometry.unitFor(canvasWidth: 600, canvasHeight: 600), 1e-9)
        // 800x600 -> fits the 600 height
        expectClose(1, GlobeGeometry.unitFor(canvasWidth: 800, canvasHeight: 600), 1e-9)
        // 600x450 (the 0.75 height ratio) -> fits the 450 height
        expectClose(0.75, GlobeGeometry.unitFor(canvasWidth: 600, canvasHeight: 450), 1e-9)
    }

    @Test func virtualCenterMapsToTheCanvasCenterOfAWideBox() {
        let center = GlobeGeometry.toCanvas(
            GlobePoint(GlobeGeometry.center, GlobeGeometry.center),
            canvasWidth: 800,
            canvasHeight: 600
        )
        expectClose(400, center.x, 1e-9)
        expectClose(300, center.y, 1e-9)
    }

    @Test func theGlobeEdgesStayInsideAWideBox() {
        let width: Double = 800
        let height: Double = 600
        // the extreme points of the virtual space (the sphere's bounding box)
        let left = GlobeGeometry.toCanvas(
            GlobePoint(0, GlobeGeometry.center), canvasWidth: width, canvasHeight: height
        )
        let right = GlobeGeometry.toCanvas(
            GlobePoint(GlobeGeometry.virtualSize, GlobeGeometry.center),
            canvasWidth: width,
            canvasHeight: height
        )
        let top = GlobeGeometry.toCanvas(
            GlobePoint(GlobeGeometry.center, 0), canvasWidth: width, canvasHeight: height
        )
        let bottom = GlobeGeometry.toCanvas(
            GlobePoint(GlobeGeometry.center, GlobeGeometry.virtualSize),
            canvasWidth: width,
            canvasHeight: height
        )
        // fits the height exactly, and is inset horizontally (centered)
        expectClose(0, top.y, 1e-9)
        expectClose(height, bottom.y, 1e-9)
        expectClose(100, left.x, 1e-9)
        expectClose(700, right.x, 1e-9)
        expectClose(width / 2 - left.x, right.x - width / 2, 1e-9)
    }

    /// The component may be shorter than it is wide (a compact sheet): the
    /// globe must still fit whole, never overflow, and stay centered.
    @Test func theGlobeFitsAndCentersInAShortBox() {
        let width: Double = 600
        let height: Double = 200
        let unit = GlobeGeometry.unitFor(canvasWidth: width, canvasHeight: height)
        expectClose(200.0 / 600.0, unit, 1e-9)
        for corner in [
            GlobePoint(0, GlobeGeometry.center),
            GlobePoint(GlobeGeometry.virtualSize, GlobeGeometry.center),
            GlobePoint(GlobeGeometry.center, 0),
            GlobePoint(GlobeGeometry.center, GlobeGeometry.virtualSize),
        ] {
            let mapped = GlobeGeometry.toCanvas(corner, canvasWidth: width, canvasHeight: height)
            #expect(-1e-9 <= mapped.x && mapped.x <= width + 1e-9)
            #expect(-1e-9 <= mapped.y && mapped.y <= height + 1e-9)
        }
    }

    @Test func toVirtualInvertsToCanvas() {
        for (width, height) in [(600.0, 600.0), (800.0, 600.0), (400.0, 700.0)] {
            for point in [
                GlobePoint(GlobeGeometry.center, GlobeGeometry.center),
                GlobePoint(120, 480),
                GlobePoint(590, 10),
            ] {
                let canvas = GlobeGeometry.toCanvas(point, canvasWidth: width, canvasHeight: height)
                let back = GlobeGeometry.toVirtual(
                    x: canvas.x, y: canvas.y, canvasWidth: width, canvasHeight: height
                )
                expectClose(point.x, back.x, 1e-9)
                expectClose(point.y, back.y, 1e-9)
            }
        }
    }

    // MARK: - helpers

    private func expectPoint(
        _ expectedX: Double,
        _ expectedY: Double,
        _ actual: GlobePoint?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual != nil, sourceLocation: sourceLocation)
        guard let actual = actual else {
            return
        }
        expectClose(expectedX, actual.x, 1e-9, sourceLocation: sourceLocation)
        expectClose(expectedY, actual.y, 1e-9, sourceLocation: sourceLocation)
    }

    private func expectClose(
        _ expected: Double,
        _ actual: Double,
        _ tolerance: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            abs(expected - actual) <= tolerance,
            "expected \(expected) +/- \(tolerance), got \(actual)",
            sourceLocation: sourceLocation
        )
    }

    private func distanceToCenter(_ point: GlobePoint) -> Double {
        let dx = point.x - GlobeGeometry.center
        let dy = point.y - GlobeGeometry.center
        return (dx * dx + dy * dy).squareRoot()
    }

    private func allEqual(_ line: [Double], offset: Int) -> Bool {
        for i in stride(from: offset + 2, to: line.count, by: 2) {
            if 1e-9 < abs(line[i] - line[offset]) {
                return false
            }
        }
        return true
    }
}
