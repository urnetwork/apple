//
//  ProviderGlobeView.swift
//  URnetwork
//

import SwiftUI
import URnetworkSdk

// visual constants, matching the /ip globe on ur.io (see PROVIDERLOCATIONS.md
// "ur.io /ip globe"). All lengths are in the 600-unit virtual space.
private let graticuleColor = Color(white: 0.8).opacity(0.376)
private let landStrokeWidth: Double = 0.3
private let graticuleStrokeWidth: Double = 0.5
private let dotRadius: Double = 7
// the selected provider keeps its solid dot; the ring is an outline sitting
// selectedRingGap outside the dot's edge (radii are stroke centerlines)
private let selectedRingGap: Double = 4
private let selectedRingStroke: Double = 1.5
private let selectedRingRadius = dotRadius + selectedRingGap + selectedRingStroke / 2
// the web globe's neutral blue for a provider whose country is unknown
private let unknownCountryColor = Color(hex: "0099FF")
// The selected provider's dot is its own country color darkened toward black.
// Same factor on every platform (see PROVIDERLOCATIONS.md), so the selection
// reads the same everywhere.
private let selectedDotDarken: Double = 0.55
// The sphere is sized to fit its box with room for a selected dot's ring at
// the limb, so the globe never paints outside the component. (The web zooms
// past its frame and crops; here the globe sits fully inside instead.)
private let globeScale = GlobeGeometry.center - dotRadius - selectedRingGap - selectedRingStroke
// Recentering is a primary interaction (every selection change recenters), not
// the web's occasional pointer-leave animation, so it is snappier than the
// web's 1000 ms — a slow curve makes stepping feel like it lags the finger.
//
// It is a spring rather than a timing curve because those steps overlap: a
// second one lands while the first is still running, and a spring retargets
// from the rotation's current position AND velocity, where an ease restarts
// from a standstill and reads as a stutter on every step. Critically damped
// (dampingFraction 1), so the globe settles onto the provider instead of
// swinging past it.
private let recenterAnimation = Animation.spring(response: 0.45, dampingFraction: 1)
private let tapSlop: Double = 28
// how far the finger travels to advance one provider, as a fraction of the
// globe's width
private let wheelStepWidthFraction: Double = 0.18
// The globe's box is normally three quarters as tall as it is wide, but never
// takes more than this share of the view — on a short window the list has to
// keep its room. The projection fit-centers, so a box shorter than 0.75 of its
// width simply draws a smaller globe rather than cropping one.
private let providerGlobeHeightWidthRatio: Double = 0.75
private let providerGlobeMaxHeightFraction: Double = 0.55

/**
 * The globe's box height for a container of this size. Sizing it explicitly
 * keeps the split with the list deterministic: two flexible siblings in a
 * VStack would otherwise negotiate the height between them.
 */
func providerGlobeHeight(in size: CGSize) -> CGFloat {
    min(
        size.width * providerGlobeHeightWidthRatio,
        size.height * providerGlobeMaxHeightFraction
    )
}

/**
 * The provider globe: a dark sphere with white land, a graticule, and one dot
 * per plottable provider colored by its country. The selected provider gets a
 * ring, and the globe is always centered on it — however the selection moved,
 * whether the user tapped a dot or a row, stepped the wheel, or the provider
 * it was resting on left the window.
 *
 * Interaction is a **scroll wheel** while there are providers to traverse: a
 * horizontal drag steps the selection through the providers ordered west to
 * east, and each step recenters the globe. Free rotation would fight that
 * animation, so it is offered only when there is nothing to traverse.
 *
 * `onStep` reports wheel steps (positive east) once a drag crosses the
 * hysteresis threshold; the wheel itself — the centroid-relative order and the
 * clamping at its ends — lives in the SDK's ProviderLocationsViewController.
 */
struct ProviderGlobeView: View {

    let rows: [ProviderLocationRow]
    let selectedClientId: String?
    let onSelect: (String) -> Void
    let onStep: (Int) -> Void

    @State private var topology: WorldTopology? = nil
    @State private var lambda: Double = 0
    @State private var phi: Double = 0
    // whether the globe has ever been placed. Only the opening fallback needs
    // it (see centerTarget): before it, an unplottable selection lands on the
    // first provider on the globe rather than nowhere; after it, the globe
    // follows the selection and nothing else.
    @State private var centeredOnce: Bool = false
    // the drag translation already accounted for, so the wheel's leftover
    // travel (its hysteresis) survives across gesture updates
    @State private var wheelConsumed: Double = 0
    @State private var freeDragAnchor: CGSize = .zero
    // SwiftUI resets a @GestureState when the gesture ends *or is cancelled*
    // (the sheet taking over the drag, say). onEnded alone does not fire on a
    // cancel, which would carry a stale accumulator into the next swipe.
    @GestureState private var dragActive: Bool = false

    private let graticule = GlobeGeometry.graticule()

    private var plottable: [ProviderLocationRow] {
        rows.filter { $0.plottable }
    }

    var body: some View {
        GeometryReader { geometry in
            GlobeCanvas(
                lambda: lambda,
                phi: phi,
                rows: plottable,
                selectedClientId: selectedClientId,
                topology: topology,
                graticule: graticule
            )
            .contentShape(Rectangle())
            .gesture(dragGesture(size: geometry.size))
            .onTapGesture(coordinateSpace: .local) { point in
                selectNearest(to: point, size: geometry.size)
            }
        }
        // The caller sizes the box (see providerGlobeHeight); the projection
        // fit-centers inside whatever it is given. globeScale already keeps
        // every draw inside the box, and this is the backstop so nothing can
        // paint over the rows below.
        .clipped()
        .task {
            // ~100 KB of TopoJSON to parse and stitch: decode off the main
            // thread so opening the view does not drop frames. The globe
            // renders (sphere, graticule, dots) while the land is loading.
            if topology == nil {
                let decoded = await Task.detached(priority: .userInitiated) {
                    WorldTopology.loadFromBundle()
                }.value
                topology = decoded
            }
        }
        // one trigger for every way the globe's center can move: the selection
        // changing, and the selected provider's own coordinates arriving or
        // changing under it. Watching the selected id alone left the globe
        // parked where it was when a row's coordinates showed up late.
        .onChange(of: centerTarget) { target in
            recenter(on: target)
        }
        .onChange(of: dragActive) { active in
            if !active {
                endDrag()
            }
        }
        .onAppear {
            recenter(on: centerTarget)
        }
    }

    // MARK: - interaction

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if plottable.isEmpty {
                    rotateFreely(value.translation, size: size)
                } else {
                    stepWheel(value.translation.width, size: size)
                }
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func endDrag() {
        wheelConsumed = 0
        freeDragAnchor = .zero
    }

    /**
     * With nothing on the globe to traverse there is no wheel, so the globe
     * rotates freely — the web's drag, at the web's sensitivity.
     */
    private func rotateFreely(_ translation: CGSize, size: CGSize) {
        let unit = GlobeGeometry.unitFor(canvasWidth: size.width, canvasHeight: size.height)
        guard 0 < unit else {
            return
        }
        let k = GlobeGeometry.dragDegreesPerVirtualPx(scale: globeScale)
        let dx = translation.width - freeDragAnchor.width
        let dy = translation.height - freeDragAnchor.height
        freeDragAnchor = translation
        lambda += dx / unit * k
        phi = min(90, max(-90, phi - dy / unit * k))
    }

    /**
     * The scroll wheel: accumulated horizontal travel past the threshold steps
     * the selection, and the step consumes exactly one threshold of travel —
     * that leftover is the hysteresis, so a finger resting on the boundary
     * cannot flicker between two providers. Swiping left advances (the globe
     * spins east under the finger). The wheel's order and its ends are the
     * SDK view controller's; this only reports the step count.
     */
    private func stepWheel(_ translationWidth: Double, size: CGSize) {
        let travel = translationWidth - wheelConsumed
        let step = GlobeGeometry.wheelStep(
            travel: travel,
            threshold: size.width * wheelStepWidthFraction
        )
        guard step.steps != 0 else {
            return
        }
        wheelConsumed = translationWidth - step.remainingTravel
        onStep(step.steps)
    }

    private func selectNearest(to point: CGPoint, size: CGSize) {
        let visible = plottable.compactMap { row -> (String, GlobePoint)? in
            guard let lon = row.lon, let lat = row.lat,
                  let projected = GlobeGeometry.project(
                    lon: lon, lat: lat, rotLambda: lambda, rotPhi: phi, scale: globeScale
                  ) else {
                return nil
            }
            return (row.id, projected)
        }
        guard !visible.isEmpty else {
            return
        }
        let tap = GlobeGeometry.toVirtual(
            x: point.x, y: point.y, canvasWidth: size.width, canvasHeight: size.height
        )
        let hit = GlobeGeometry.nearestWithin(
            x: tap.x, y: tap.y, points: visible.map { $0.1 }, radius: tapSlop
        )
        if 0 <= hit {
            onSelect(visible[hit].0)
        }
    }

    // MARK: - centering

    /**
     * Where the globe belongs: the selected provider's position on the sphere.
     * nil when there is nothing to center on — no providers yet, or a selected
     * provider with no coordinates, which has no dot to center under.
     *
     * Until the globe has centered once the first plottable provider stands in
     * for a selection that cannot be plotted, so opening the view lands on a
     * provider rather than on the empty Atlantic at (0, 0). After that the
     * globe follows the selection only: chasing the first row as the window
     * turns over would yank the globe around for no reason the user can see.
     */
    private var centerTarget: GlobeCenterTarget? {
        let visible = plottable
        let target = visible.first { $0.id == selectedClientId }
            ?? (centeredOnce ? nil : visible.first)
        guard let target = target, let lat = target.lat, let lon = target.lon else {
            return nil
        }
        return GlobeCenterTarget(clientId: target.id, lat: lat, lon: lon)
    }

    /**
     * Spins the globe to the target, taking the short way round.
     * `lerpRotation(t: 1)` resolves the target to its nearest equivalent angle,
     * so SwiftUI's linear interpolation of lambda is already the short path.
     */
    private func recenter(on target: GlobeCenterTarget?) {
        guard let target = target else {
            return
        }
        // the globe is now placed, even if it was already pointing here
        centeredOnce = true
        let to = GlobeGeometry.rotationCentering(lon: target.lon, lat: target.lat)
        let shortest = GlobeGeometry.lerpRotation(from: (lambda, phi), to: to, t: 1)
        guard shortest.lambda != lambda || shortest.phi != phi else {
            // nothing to animate; restarting the spring here would only add a
            // stutter to a globe that is already on the provider
            return
        }
        withAnimation(recenterAnimation) {
            lambda = shortest.lambda
            phi = shortest.phi
        }
    }
}

/// The rotation the globe is animating toward, identified by the provider it
/// belongs to: comparing the coordinates as well as the id is what makes a
/// provider whose position changes under the selection recenter the globe.
private struct GlobeCenterTarget: Equatable {
    let clientId: String
    let lat: Double
    let lon: Double
}

/**
 * The globe's drawing surface. `Animatable` on the view itself is what lets
 * SwiftUI interpolate the rotation across the recenter animation — the Canvas
 * closure reads the interpolated values on every frame.
 */
private struct GlobeCanvas: View, Animatable {

    var lambda: Double
    var phi: Double
    let rows: [ProviderLocationRow]
    let selectedClientId: String?
    let topology: WorldTopology?
    let graticule: [[Double]]

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(lambda, phi) }
        set {
            lambda = newValue.first
            phi = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            // fit center: the globe is scaled to the smaller dimension and
            // centered in both, so a non-square box neither crops nor offsets it
            let unit = GlobeGeometry.unitFor(canvasWidth: size.width, canvasHeight: size.height)

            func canvasPoint(_ point: GlobePoint) -> CGPoint {
                let mapped = GlobeGeometry.toCanvas(
                    point, canvasWidth: size.width, canvasHeight: size.height
                )
                return CGPoint(x: mapped.x, y: mapped.y)
            }

            // the sphere
            let radius = globeScale * unit
            let sphere = CGRect(
                x: size.width / 2 - radius,
                y: size.height / 2 - radius,
                width: 2 * radius,
                height: 2 * radius
            )
            context.fill(Path(ellipseIn: sphere), with: .color(.urBlack))

            // land: filled countries with a hairline border, clamped at the horizon
            if let topology = topology {
                for country in topology.countries {
                    for ring in country.rings {
                        guard let path = landPath(ring: ring, canvasPoint: canvasPoint) else {
                            continue
                        }
                        context.fill(path, with: .color(.urWhite))
                        context.stroke(
                            path,
                            with: .color(.urBlack),
                            lineWidth: landStrokeWidth * unit
                        )
                    }
                }
            }

            // graticule over the land, as on the web
            for line in graticule {
                for path in polylinePaths(line: line, canvasPoint: canvasPoint) {
                    context.stroke(
                        path,
                        with: .color(graticuleColor),
                        lineWidth: graticuleStrokeWidth * unit
                    )
                }
            }

            // Provider dots. The selected one is held back and drawn last so it
            // is never covered by a dot that happens to sit on top of it —
            // providers in one city land on the same pixel.
            var selected: (center: CGPoint, color: Color)? = nil
            let r = dotRadius * unit
            for row in rows {
                guard let lon = row.lon, let lat = row.lat,
                      let projected = GlobeGeometry.project(
                        lon: lon, lat: lat, rotLambda: lambda, rotPhi: phi, scale: globeScale
                      ) else {
                    continue
                }
                let center = canvasPoint(projected)
                let color = providerDotColor(row)
                if row.id == selectedClientId {
                    selected = (center, color)
                    continue
                }
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(color)
                )
            }
            if let selected {
                // a darker core inside its own full-strength ring: the selection
                // reads at a glance without changing which country color it is
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: selected.center.x - r,
                        y: selected.center.y - r,
                        width: 2 * r,
                        height: 2 * r
                    )),
                    with: .color(selected.color.darkenedForSelection())
                )
                let ringR = selectedRingRadius * unit
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: selected.center.x - ringR,
                        y: selected.center.y - ringR,
                        width: 2 * ringR,
                        height: 2 * ringR
                    )),
                    with: .color(selected.color),
                    lineWidth: selectedRingStroke * unit
                )
            }
        }
    }

    /**
     * One country ring as a closed path, with back-hemisphere points clamped to
     * the silhouette so a shape crossing the horizon still fills correctly.
     * Returns nil when the whole ring is on the far side.
     */
    private func landPath(ring: [Double], canvasPoint: (GlobePoint) -> CGPoint) -> Path? {
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

    /**
     * One lon/lat polyline, broken wherever it crosses the horizon so the back
     * half is not drawn as a chord across the sphere.
     */
    private func polylinePaths(line: [Double], canvasPoint: (GlobePoint) -> CGPoint) -> [Path] {
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

/**
 * The dot color is the provider's country color (the same palette the location
 * list uses). Providers whose country is unknown fall back to the web globe's
 * neutral blue.
 */
func providerDotColor(_ row: ProviderLocationRow) -> Color {
    if row.countryCode.isEmpty {
        return unknownCountryColor
    }
    return Color(hex: SdkGetColorHex(row.countryCode.lowercased()))
}

private extension Color {
    /// The same color, darkened toward black for the selected provider's dot.
    func darkenedForSelection() -> Color {
        #if canImport(UIKit)
        let components = UIColor(self).cgColor.components ?? []
        #else
        let components = NSColor(self).cgColor.components ?? []
        #endif
        guard 3 <= components.count else {
            return self
        }
        return Color(
            .sRGB,
            red: Double(components[0]) * selectedDotDarken,
            green: Double(components[1]) * selectedDotDarken,
            blue: Double(components[2]) * selectedDotDarken,
            opacity: 4 <= components.count ? Double(components[3]) : 1
        )
    }
}
