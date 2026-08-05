//
//  GlobeGeometry.swift
//  URnetwork
//
//  Orthographic globe projection math for the provider-locations globe.
//  Pure value math with no SwiftUI dependency, so it is unit tested directly
//  (GlobeGeometryTests) — a port of the Android GlobeGeometry.kt, which is
//  itself a port of the ur.io /ip d3 globe.
//

import Foundation

/// A point in the 600x600 virtual drawing space.
struct GlobePoint: Equatable {
    let x: Double
    let y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// The result of resolving a wheel drag; see `GlobeGeometry.wheelStep`.
struct GlobeWheelStep: Equatable {
    let steps: Int
    let remainingTravel: Double
}

/**
 * Orthographic globe projection math, a faithful port of the web globe
 * (d3.geoOrthographic with clipAngle 90, see ur.io Globe.jsx). Everything is
 * in a 600x600 virtual space with the globe centered at (300, 300); the view
 * maps virtual space to its canvas.
 *
 * Rotation is the d3 `projection.rotate([lambda, phi])` convention, degrees:
 * the globe is rotated by (+lambda, +phi), so the point centered on screen is
 * (lon = -lambda, lat = -phi).
 */
enum GlobeGeometry {

    static let virtualSize: Double = 600
    static let center: Double = 300

    private static let degreesToRadians = Double.pi / 180

    /**
     * Projects (lon, lat) under rotation (rotLambda, rotPhi) at the given
     * scale (globe radius in virtual px; the web starts at 300). Returns nil
     * for points on the back hemisphere (angular distance to the view center
     * greater than 90 degrees), matching d3 clipAngle(90).
     */
    static func project(
        lon: Double,
        lat: Double,
        rotLambda: Double,
        rotPhi: Double,
        scale: Double
    ) -> GlobePoint? {
        let towardViewer = rotateTowardViewer(lon, lat, rotLambda, rotPhi)
        if towardViewer < 0 {
            return nil
        }
        let right = rotateRight(lon, lat, rotLambda)
        let up = rotateUp(lon, lat, rotLambda, rotPhi)
        return GlobePoint(center + scale * right, center - scale * up)
    }

    /**
     * Like `project`, but never nil: back-hemisphere points are clamped to
     * the silhouette circle of radius `scale` in their azimuthal direction, so
     * polygon fills that cross the horizon stay on the visible disk. The exact
     * antipode of the view center has no direction; it clamps to
     * (center + scale, center) deterministically.
     */
    static func projectClamped(
        lon: Double,
        lat: Double,
        rotLambda: Double,
        rotPhi: Double,
        scale: Double
    ) -> GlobePoint {
        let towardViewer = rotateTowardViewer(lon, lat, rotLambda, rotPhi)
        let right = rotateRight(lon, lat, rotLambda)
        let up = rotateUp(lon, lat, rotLambda, rotPhi)
        if 0 <= towardViewer {
            return GlobePoint(center + scale * right, center - scale * up)
        }
        let length = (right * right + up * up).squareRoot()
        if length < 1e-9 {
            return GlobePoint(center + scale, center)
        }
        return GlobePoint(
            center + scale * right / length,
            center - scale * up / length
        )
    }

    /**
     * Cosine of the angular distance from (lon, lat) to the view center under
     * the given rotation. The point is on the visible hemisphere iff >= 0.
     */
    static func cosAngleToCenter(
        lon: Double,
        lat: Double,
        rotLambda: Double,
        rotPhi: Double
    ) -> Double {
        rotateTowardViewer(lon, lat, rotLambda, rotPhi)
    }

    /// The rotation that centers (lon, lat) on screen: (-lon, -lat).
    static func rotationCentering(lon: Double, lat: Double) -> (lambda: Double, phi: Double) {
        (-lon, -lat)
    }

    /**
     * Componentwise interpolation between two rotations with longitude taking
     * the shorter way around (so 170 -> -170 passes through 180, not 0) and
     * phi clamped to [-90, 90].
     */
    static func lerpRotation(
        from: (lambda: Double, phi: Double),
        to: (lambda: Double, phi: Double),
        t: Double
    ) -> (lambda: Double, phi: Double) {
        var deltaLambda = (to.lambda - from.lambda).truncatingRemainder(dividingBy: 360)
        if 180 < deltaLambda {
            deltaLambda -= 360
        }
        if deltaLambda < -180 {
            deltaLambda += 360
        }
        let phi = from.phi + (to.phi - from.phi) * t
        return (from.lambda + deltaLambda * t, min(90, max(-90, phi)))
    }

    /**
     * Drag sensitivity in degrees of rotation per virtual px of drag at the
     * given scale. Web parity (Globe.jsx drag handler):
     *
     *     const k = width / projection.scale() / (3 * Math.PI);
     *     projection.rotate([r[0] + event.dx * k, r[1] - event.dy * k]);
     *
     * projection.rotate() takes degrees, so k is degrees per px: at the
     * initial scale 300, k = 600 / 300 / (3 * pi) = 2 / (3 * pi) = 0.21221
     * degrees per px, i.e. dragging across the full 600 px width turns the
     * globe by ~127 degrees. Callers apply +dx * k to lambda and -dy * k to
     * phi, as the web does.
     */
    static func dragDegreesPerVirtualPx(scale: Double) -> Double {
        virtualSize / scale / (3 * Double.pi)
    }

    /**
     * Graticule polylines in lon/lat degrees, [lon0, lat0, lon1, lat1, ...],
     * matching d3.geoGraticule() defaults (d3-geo graticule.js): minor
     * meridians every 10 degrees of lon (skipping multiples of 90) spanning
     * lat -80..80, minor parallels every 10 degrees of lat from -80..80
     * (skipping the equator) spanning lon -180..180, major meridians at -180,
     * -90, 0 and 90 spanning the full lat range, and the equator as the single
     * major parallel. Lines are sampled every 2.5 degrees (d3's default
     * precision; d3 emits sparse meridians and lets projected adaptive
     * resampling curve them, which comes to the same drawn shape).
     *
     * Rotation-independent, computed once; `project` applies rotation at draw
     * time.
     */
    static func graticule() -> [[Double]] {
        cachedGraticule
    }

    /**
     * One horizontal drag resolved against the wheel's hysteresis threshold:
     * how many providers to advance, and the travel carried into the next
     * step. Swiping left (negative travel) advances forward, matching the
     * globe spinning east under the finger.
     *
     * The leftover travel is what makes it hysteretic: after a step the user
     * must drag another full threshold to step again, so a finger resting near
     * the boundary cannot flicker between two providers.
     */
    static func wheelStep(travel: Double, threshold: Double) -> GlobeWheelStep {
        if threshold <= 0 {
            return GlobeWheelStep(steps: 0, remainingTravel: 0)
        }
        // truncates toward zero, so a fast drag can cross several steps at once
        let steps = Int(-travel / threshold)
        return GlobeWheelStep(
            steps: steps,
            remainingTravel: travel + Double(steps) * threshold
        )
    }

    /**
     * Advances an index by `steps`, wrapping at both ends. Wrapping is the
     * right model here because the wheel is ordered by longitude, which is
     * cyclic: stepping east past the last provider lands on the westernmost,
     * which is also the shortest way round the globe.
     */
    static func wrapIndex(index: Int, steps: Int, count: Int) -> Int {
        if count <= 0 {
            return -1
        }
        let next = (index + steps) % count
        return next < 0 ? next + count : next
    }

    /**
     * Fit-center layout: the virtual space is scaled to the SMALLER canvas
     * dimension and centered in both, so the globe fits whole and stays
     * centered whatever the box's aspect ratio.
     */
    static func unitFor(canvasWidth: Double, canvasHeight: Double) -> Double {
        min(canvasWidth, canvasHeight) / virtualSize
    }

    /// A point in the 600-unit virtual space -> canvas px, fit-centered.
    static func toCanvas(_ point: GlobePoint, canvasWidth: Double, canvasHeight: Double) -> GlobePoint {
        let unit = unitFor(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return GlobePoint(
            canvasWidth / 2 + (point.x - center) * unit,
            canvasHeight / 2 + (point.y - center) * unit
        )
    }

    /// Canvas px -> the 600-unit virtual space; the inverse of `toCanvas`.
    static func toVirtual(x: Double, y: Double, canvasWidth: Double, canvasHeight: Double) -> GlobePoint {
        let unit = unitFor(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        if unit <= 0 {
            return GlobePoint(center, center)
        }
        return GlobePoint(
            center + (x - canvasWidth / 2) / unit,
            center + (y - canvasHeight / 2) / unit
        )
    }

    /**
     * Index of the point nearest to (x, y) within `radius` (inclusive, in
     * virtual px), or -1 if none is in range. Ties keep the earliest index.
     */
    static func nearestWithin(x: Double, y: Double, points: [GlobePoint], radius: Double) -> Int {
        let radiusSquared = radius * radius
        var best = -1
        var bestDistanceSquared = Double.greatestFiniteMagnitude
        for i in points.indices {
            let dx = points[i].x - x
            let dy = points[i].y - y
            let distanceSquared = dx * dx + dy * dy
            if distanceSquared <= radiusSquared && distanceSquared < bestDistanceSquared {
                best = i
                bestDistanceSquared = distanceSquared
            }
        }
        return best
    }

    // Rotation, ported from d3-geo rotation.js rotateRadians(dl, dp, 0):
    // rotationLambda(dl) first adds dl to the longitude, then
    // rotationPhiGamma(dp, 0) takes the unit vector
    //     x = cos(lambda1) * cos(phi1)   // toward the viewer
    //     y = sin(lambda1) * cos(phi1)   // screen right
    //     z = sin(phi1)                  // screen up (north)
    // and returns [atan2(y, x * cos(dp) - z * sin(dp)),
    //              asin(z * cos(dp) + x * sin(dp))]
    // which is the rotation about the screen-right axis mapping
    //     (x, y, z) -> (x cos dp - z sin dp, y, z cos dp + x sin dp).
    // The orthographic raw projection of the rotated (lambda2, phi2) is
    //     [cos(phi2) * sin(lambda2), sin(phi2)] = (rotated y, rotated z)
    // and cos(angular distance to the view center) = cos(phi2) * cos(lambda2)
    // = rotated x, so the three component functions below are the whole
    // pipeline with no inverse trig.

    /// Rotated x: cosine of the angular distance to the view center.
    private static func rotateTowardViewer(
        _ lonDeg: Double,
        _ latDeg: Double,
        _ rotLambdaDeg: Double,
        _ rotPhiDeg: Double
    ) -> Double {
        let lambda = (lonDeg + rotLambdaDeg) * degreesToRadians
        let phi = latDeg * degreesToRadians
        let deltaPhi = rotPhiDeg * degreesToRadians
        return cos(lambda) * cos(phi) * cos(deltaPhi) - sin(phi) * sin(deltaPhi)
    }

    /// Rotated y: the raw orthographic screen-right coordinate, [-1, 1].
    private static func rotateRight(
        _ lonDeg: Double,
        _ latDeg: Double,
        _ rotLambdaDeg: Double
    ) -> Double {
        let lambda = (lonDeg + rotLambdaDeg) * degreesToRadians
        let phi = latDeg * degreesToRadians
        return sin(lambda) * cos(phi)
    }

    /// Rotated z: the raw orthographic screen-up coordinate, [-1, 1].
    private static func rotateUp(
        _ lonDeg: Double,
        _ latDeg: Double,
        _ rotLambdaDeg: Double,
        _ rotPhiDeg: Double
    ) -> Double {
        let lambda = (lonDeg + rotLambdaDeg) * degreesToRadians
        let phi = latDeg * degreesToRadians
        let deltaPhi = rotPhiDeg * degreesToRadians
        return sin(phi) * cos(deltaPhi) + cos(lambda) * cos(phi) * sin(deltaPhi)
    }

    // Graticule construction, ported from d3-geo graticule.js defaults:
    // extentMajor [[-180, -90 + eps], [180, 90 - eps]], extentMinor
    // [[-180, -80 - eps], [180, 80 + eps]], stepMinor [10, 10], stepMajor
    // [90, 360], precision 2.5. d3's lines() emits major meridians
    // range(-180, 180, 90), major parallels range(0, 90 - eps, 360) (the
    // equator only), minor meridians range(-180, 180, 10) filtered to
    // abs(lon % 90) > eps, and minor parallels range(-80, 80 + eps, 10)
    // filtered to abs(lat % 360) > eps.

    private static let graticuleEpsilon: Double = 1e-6
    private static let graticulePrecision: Double = 2.5

    private static let cachedGraticule: [[Double]] = buildGraticule()

    private static func buildGraticule() -> [[Double]] {
        var lines: [[Double]] = []
        lines.reserveCapacity(53)
        // major meridians every 90 degrees, pole to pole
        var lon: Double = -180
        while lon < 180 {
            lines.append(meridian(lon: lon, latStart: -90 + graticuleEpsilon, latEnd: 90 - graticuleEpsilon))
            lon += 90
        }
        // the equator, the only major parallel
        lines.append(parallel(lat: 0))
        // minor meridians every 10 degrees, spanning lat -80..80
        lon = -180
        while lon < 180 {
            if graticuleEpsilon < abs(lon.truncatingRemainder(dividingBy: 90)) {
                lines.append(
                    meridian(lon: lon, latStart: -80 - graticuleEpsilon, latEnd: 80 + graticuleEpsilon)
                )
            }
            lon += 10
        }
        // minor parallels every 10 degrees from -80..80, skipping the equator
        var lat: Double = -80
        while lat <= 80 + graticuleEpsilon {
            if graticuleEpsilon < abs(lat) {
                lines.append(parallel(lat: lat))
            }
            lat += 10
        }
        return lines
    }

    /**
     * Sample positions along [start, end] every `graticulePrecision` degrees
     * with d3 range semantics: start + i * step for i in 0 until
     * ceil((end - eps - start) / step), then the exact end appended.
     */
    private static func sampleSpan(start: Double, end: Double) -> [Double] {
        let steps = Int(((end - graticuleEpsilon - start) / graticulePrecision).rounded(.up))
        return (0...steps).map { i in
            i == steps ? end : start + Double(i) * graticulePrecision
        }
    }

    private static func meridian(lon: Double, latStart: Double, latEnd: Double) -> [Double] {
        let lats = sampleSpan(start: latStart, end: latEnd)
        var line = [Double](repeating: 0, count: lats.count * 2)
        for i in lats.indices {
            line[2 * i] = lon
            line[2 * i + 1] = lats[i]
        }
        return line
    }

    private static func parallel(lat: Double) -> [Double] {
        let lons = sampleSpan(start: -180, end: 180)
        var line = [Double](repeating: 0, count: lons.count * 2)
        for i in lons.indices {
            line[2 * i] = lons[i]
            line[2 * i + 1] = lat
        }
        return line
    }
}
