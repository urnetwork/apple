//
//  GoldPlanDress.swift
//  URnetwork
//
//  The Pro-gold dress of the recommended sign-up box: a breathing halo of
//  fading rings that follows the box, an opaque ground with a gold wash
//  brighter at the top left, and a white light that runs around the gold
//  border. Both motions stop under reduced motion, leaving the static gold
//  dress.
//

import SwiftUI

/// Pro gold: the plan is the Pro entitlement, so it wears the Pro ring's gold, not referral gold.
let introProGold = Color(red: 1.0, green: 0.77, blue: 0.0)
let introProGoldLight = Color(red: 1.0, green: 0.88, blue: 0.51)

private let goldDressSweepSeconds = 3.6
private let goldDressBreathSeconds = 4.4

struct GoldPlanDress: ViewModifier {

    var selected: Bool = true
    var cornerRadius: CGFloat = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(GoldDressGround(cornerRadius: cornerRadius))
            .background(
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let breath = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t / goldDressBreathSeconds * 2 * .pi)
                    GoldHalo(cornerRadius: cornerRadius, breath: breath)
                }
                .padding(-28)
                .allowsHitTesting(false)
            )
            .overlay(
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let sweep = reduceMotion ? 0.25 : t.truncatingRemainder(dividingBy: goldDressSweepSeconds) / goldDressSweepSeconds
                    GoldRunningBorder(cornerRadius: cornerRadius, sweep: sweep, selected: selected)
                }
                .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Draws the gold dress behind and around the view.
    func goldPlanDress(selected: Bool = true, cornerRadius: CGFloat = 12) -> some View {
        modifier(GoldPlanDress(selected: selected, cornerRadius: cornerRadius))
    }
}

/// Opaque ground, then the gold wash with a brighter top-left.
private struct GoldDressGround: View {

    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.urBlack)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(introProGold.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        RadialGradient(
                            colors: [introProGold.opacity(0.18), introProGold.opacity(0)],
                            center: UnitPoint(x: 0.1, y: 0),
                            startRadius: 0,
                            endRadius: 420
                        )
                    )
            )
    }
}

/// The breathing halo: rings that follow the box's shape and fade out over the spill, brightest against the border.
private struct GoldHalo: View {

    let cornerRadius: CGFloat
    let breath: Double

    var body: some View {
        Canvas { context, size in
            let spill: CGFloat = 28
            let rings = 44
            let ringWidth = spill / CGFloat(rings)
            let peak = 0.20 + 0.14 * breath
            let box = CGRect(x: spill, y: spill, width: size.width - 2 * spill, height: size.height - 2 * spill)
            for ring in 0..<rings {
                let t = Double(ring) / Double(rings - 1)
                let distance = ringWidth * (CGFloat(ring) + 0.5)
                let fade = (1 - t) * (1 - t)
                let rect = box.insetBy(dx: -distance, dy: -distance)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius + distance)
                context.stroke(path, with: .color(introProGold.opacity(peak * fade)), lineWidth: ringWidth + 0.5)
            }
        }
    }
}

/// The border: solid gold with a bright light travelling around it.
private struct GoldRunningBorder: View {

    let cornerRadius: CGFloat
    let sweep: Double
    let selected: Bool

    var body: some View {
        let base = selected ? introProGold : introProGold.opacity(0.7)
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: introProGoldLight, location: 0.07),
                        .init(color: base, location: 0.14),
                        .init(color: base, location: 0.86),
                        .init(color: introProGoldLight, location: 0.93),
                        .init(color: .white, location: 1),
                    ]),
                    center: .center,
                    angle: .degrees(sweep * 360)
                ),
                lineWidth: 2
            )
    }
}

/// The gold "Best value" pill that sits on the box's top-right corner.
struct BestValuePill: View {
    var body: some View {
        Text("Best value")
            .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
            .foregroundColor(.urBlack)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                LinearGradient(colors: [introProGoldLight, introProGold], startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: introProGold.opacity(0.6), radius: 10)
    }
}
