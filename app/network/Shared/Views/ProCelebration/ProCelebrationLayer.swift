//
//  ProCelebrationLayer.swift
//  URnetwork
//
//  Hosts the Pro celebration over a view: while a flight is in the air the
//  view's content is pixelated (a mosaic whose cell grows over the first
//  5 s, holds while the confetti flies, and shrinks back over the 5 s after
//  it) and the confetti draws above it, sharp. Idle, the layer adds nothing:
//  no effect, no overlay.
//
//  The mosaic cell is an animated value: SwiftUI interpolates it, so the
//  content under it is not re-rendered every frame (a tab view is UIKit
//  backed, and re-rendering it under a per-frame timeline re-hosts it above
//  the overlay). Only the confetti canvas runs on a frame timeline.
//
//  iOS 17 / macOS 14 pixelate with a Metal layer effect
//  (ProPixellate.metal); earlier systems blur with the same envelope.
//

import SwiftUI

extension View {
    /// Plays the Pro celebration over this view whenever the shared
    /// `ProCelebrationState` launches one. Apply at the app root and inside
    /// modal presentations (the upgrade sheet, the onboarding cover), which
    /// draw above the root.
    func proCelebrationLayer() -> some View {
        modifier(ProCelebrationLayer())
    }
}

private struct ProCelebrationLayer: ViewModifier {

    @EnvironmentObject private var celebration: ProCelebrationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The sequence in the air and its launch moment; nil when idle.
    @State private var flight: (sequence: Int, startedAt: Date)? = nil
    /// The mosaic cell in points, animated through the envelope; 0 = sharp.
    @State private var cell: Double = 0
    @State private var envelopeTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        ZStack {
            content
                .modifier(ProPixelation(cell: cell))
            if let flight {
                ProFlightOverlay(sequence: flight.sequence, startedAt: flight.startedAt)
            }
        }
        .onChange(of: celebration.sequence) { sequence in
            start(sequence)
        }
        .onAppear {
            // a flight launched before this host existed (a sheet opening mid-flight)
            if celebration.sequence != 0 && flight?.sequence != celebration.sequence {
                start(celebration.sequence)
            }
        }
        .onDisappear {
            envelopeTask?.cancel()
            envelopeTask = nil
            flight = nil
            cell = 0
        }
    }

    private func start(_ sequence: Int) {
        envelopeTask?.cancel()
        envelopeTask = nil
        guard sequence != 0 else {
            flight = nil
            withAnimation(nil) { cell = 0 }
            return
        }
        if reduceMotion {
            // no flight and no effect; report it flown so the launcher goes idle
            flight = nil
            celebration.finish(sequence)
            return
        }
        flight = (sequence, Date())
        // the envelope: ease in to the coarsest cell, hold, ease out after the confetti
        withAnimation(.easeIn(duration: ProCelebrationTiming.pixelateInSeconds)) {
            cell = ProCelebrationTiming.pixelateMaxCell
        }
        envelopeTask = Task { @MainActor in
            let outStart = UInt64(ProCelebrationTiming.pixelateOutStartSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: outStart)
            guard !Task.isCancelled, flight?.sequence == sequence else {
                return
            }
            withAnimation(.easeOut(duration: ProCelebrationTiming.pixelateOutSeconds)) {
                cell = 0
            }
            let outEnd = UInt64(ProCelebrationTiming.pixelateOutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: outEnd)
            guard !Task.isCancelled, flight?.sequence == sequence else {
                return
            }
            flight = nil
            celebration.finish(sequence)
        }
    }
}

/// The confetti canvas on its own frame timeline: it is the only view that re-renders per
/// frame. It removes itself once the confetti window has passed.
private struct ProFlightOverlay: View {

    let sequence: Int
    let startedAt: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSince(startedAt)
            if seconds < ProCelebrationTiming.confettiSeconds {
                ProSpriteFlight(sequence: sequence, seconds: seconds)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The mosaic under the confetti. `cell` is the pixel size in points; at 1pt or less the
/// effect is disabled. The view structure never changes with `cell`: switching between a
/// bare and an effect-wrapped content re-hosts a UIKit-backed child (a tab view) above the
/// overlay, so the effect is always attached and merely toggled.
private struct ProPixelation: ViewModifier, Animatable {

    var cell: Double

    var animatableData: Double {
        get { cell }
        set { cell = newValue }
    }

    private var enabled: Bool {
        cell > 1
    }

    func body(content: Content) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            content.visualEffect { [cell, enabled] view, proxy in
                view.layerEffect(
                    ShaderLibrary.proPixellate(
                        .float(Float(max(cell, 1))),
                        .float2(Float(proxy.size.width), Float(proxy.size.height))
                    ),
                    maxSampleOffset: CGSize(
                        width: ProCelebrationTiming.pixelateMaxCell,
                        height: ProCelebrationTiming.pixelateMaxCell
                    ),
                    isEnabled: enabled
                )
            }
        } else {
            // the nearest approximation on earlier systems: a blur of the same envelope
            content.blur(radius: enabled ? cell / 2 : 0)
        }
    }
}
