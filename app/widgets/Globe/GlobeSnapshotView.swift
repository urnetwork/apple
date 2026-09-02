//
//  GlobeSnapshotView.swift
//  URnetworkWidgets
//
//  A static rendering of the app's provider globe (Shared/Views/Connect/
//  ProviderGlobeView.swift): the same 600x600 virtual space, orthographic
//  projection (GlobeGeometry), Natural Earth 110m land (WorldTopology) and
//  d3 graticule, drawn once per timeline entry with the globe turned to face
//  the providers' centroid. No animation and no selection: a widget cannot
//  animate a recenter, and there is nothing to select.
//

import SwiftUI

struct GlobeSnapshotView: View {

    let providers: [WidgetProviderSnapshot]

    // virtual-space constants shared with the app's globe
    private static let dotRadius: Double = 7
    private static let globeScale: Double = 300 - 7 - 4 - 1.5
    private static let landStrokeWidth: Double = 0.3
    private static let graticuleStrokeWidth: Double = 0.5
    private static let graticuleColor = Color(white: 0.8).opacity(0.376)
    /// Widgets draw the globe far smaller than the app does; keep the dots
    /// legible.
    private static let minimumDotRadius: CGFloat = 2.5

    /// Where the globe faces when there is nothing to face: the Atlantic,
    /// so land is visible either way.
    private static let defaultView = (lon: -30.0, lat: 25.0)

    /// The land is decoded once per widget process. ~100 KB of TopoJSON.
    private static let topology: WorldTopology? = WorldTopology.loadFromBundle()
    private static let graticule: [[Double]] = GlobeGeometry.graticule()

    var body: some View {
        let rotation = Self.rotation(facing: providers)
        Canvas { context, size in
            Self.draw(
                &context, size: size, providers: providers,
                lambda: rotation.lambda, phi: rotation.phi
            )
        }
        .accessibilityLabel(Text("\(providers.count) providers"))
    }

    /// Rotation that centers the providers' spherical centroid, or the
    /// default view when none can be plotted.
    static func rotation(facing providers: [WidgetProviderSnapshot]) -> (lambda: Double, phi: Double) {
        var x = 0.0, y = 0.0, z = 0.0
        var count = 0
        for provider in providers {
            guard let lat = provider.lat, let lon = provider.lon else { continue }
            let latRadians = lat * .pi / 180
            let lonRadians = lon * .pi / 180
            x += cos(latRadians) * cos(lonRadians)
            y += cos(latRadians) * sin(lonRadians)
            z += sin(latRadians)
            count += 1
        }
        let norm = (x * x + y * y + z * z).squareRoot()
        guard 0 < count, 1e-6 < norm else {
            return GlobeGeometry.rotationCentering(lon: defaultView.lon, lat: defaultView.lat)
        }
        let lon = atan2(y, x) * 180 / .pi
        let lat = asin(max(-1, min(1, z / norm))) * 180 / .pi
        return GlobeGeometry.rotationCentering(lon: lon, lat: lat)
    }

    private static func draw(
        _ context: inout GraphicsContext,
        size: CGSize,
        providers: [WidgetProviderSnapshot],
        lambda: Double,
        phi: Double
    ) {
        let unit = GlobeGeometry.unitFor(canvasWidth: size.width, canvasHeight: size.height)

        func canvasPoint(_ point: GlobePoint) -> CGPoint {
            let mapped = GlobeGeometry.toCanvas(point, canvasWidth: size.width, canvasHeight: size.height)
            return CGPoint(x: mapped.x, y: mapped.y)
        }

        let radius = globeScale * unit
        let sphere = CGRect(
            x: size.width / 2 - radius, y: size.height / 2 - radius,
            width: 2 * radius, height: 2 * radius
        )
        context.fill(Path(ellipseIn: sphere), with: .color(WidgetTheme.urBlack))

        if let topology {
            for country in topology.countries {
                for ring in country.rings {
                    guard let path = landPath(ring: ring, lambda: lambda, phi: phi, canvasPoint: canvasPoint) else {
                        continue
                    }
                    context.fill(path, with: .color(WidgetTheme.urWhite))
                    context.stroke(path, with: .color(WidgetTheme.urBlack), lineWidth: landStrokeWidth * unit)
                }
            }
        }

        for line in graticule {
            for path in polylinePaths(line: line, lambda: lambda, phi: phi, canvasPoint: canvasPoint) {
                context.stroke(path, with: .color(graticuleColor), lineWidth: graticuleStrokeWidth * unit)
            }
        }

        let r = max(minimumDotRadius, dotRadius * unit)
        for provider in providers {
            guard let lat = provider.lat, let lon = provider.lon,
                  let projected = GlobeGeometry.project(
                    lon: lon, lat: lat, rotLambda: lambda, rotPhi: phi, scale: globeScale
                  ) else {
                continue
            }
            let center = canvasPoint(projected)
            let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(Color(hexString: provider.colorHex)))
            // a hairline of the sphere color keeps overlapping dots distinct
            context.stroke(dot, with: .color(WidgetTheme.urBlack), lineWidth: 0.5)
        }
    }

    /// One country ring as a closed path, back-hemisphere points clamped to
    /// the silhouette; nil when the ring is entirely on the far side.
    private static func landPath(
        ring: [Double], lambda: Double, phi: Double, canvasPoint: (GlobePoint) -> CGPoint
    ) -> Path? {
        var path = Path()
        var started = false
        var anyVisible = false
        var i = 0
        while i + 1 < ring.count {
            let lon = ring[i]
            let lat = ring[i + 1]
            if 0 <= GlobeGeometry.cosAngleToCenter(lon: lon, lat: lat, rotLambda: lambda, rotPhi: phi) {
                anyVisible = true
            }
            let point = GlobeGeometry.projectClamped(
                lon: lon, lat: lat, rotLambda: lambda, rotPhi: phi, scale: globeScale
            )
            let offset = canvasPoint(point)
            if started {
                path.addLine(to: offset)
            } else {
                path.move(to: offset)
                started = true
            }
            i += 2
        }
        guard anyVisible else {
            return nil
        }
        path.closeSubpath()
        return path
    }

    /// One lon/lat polyline, broken where it crosses the horizon.
    private static func polylinePaths(
        line: [Double], lambda: Double, phi: Double, canvasPoint: (GlobePoint) -> CGPoint
    ) -> [Path] {
        var paths: [Path] = []
        var path: Path? = nil
        var i = 0
        while i + 1 < line.count {
            if let projected = GlobeGeometry.project(
                lon: line[i], lat: line[i + 1], rotLambda: lambda, rotPhi: phi, scale: globeScale
            ) {
                let offset = canvasPoint(projected)
                if path == nil {
                    var started = Path()
                    started.move(to: offset)
                    path = started
                } else {
                    path?.addLine(to: offset)
                }
            } else if let finished = path {
                paths.append(finished)
                path = nil
            }
            i += 2
        }
        if let finished = path {
            paths.append(finished)
        }
        return paths
    }
}
