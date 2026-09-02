//
//  IntroTraveller.swift
//  URnetwork
//
//  The ur.io docs route line for the first onboarding page: a dashed line
//  from "You" through the URnetwork connector to "Internet", with one of the
//  pixel-art ur-people (the docs' travellers, on their connector-shaped
//  tiles) walking along it, trip after trip. A new person makes each trip,
//  drawn from a shuffled deck so all of them appear before any repeats, and
//  the traveller fades in at the start and out at the end like the docs
//  (react/src/pages/Docs.jsx RouteLine, styles/docs-explorer.css dxlPacket).
//  Under reduced motion person 0 rests near the internet end.
//

import SwiftUI

/// The connector's size in the route on page 1; the host flies it into the header from here.
let introductionRouteConnectorSize: CGFloat = 72

struct IntroTraveller: View {

    private static let tripSeconds: TimeInterval = 6.5
    private static let people = ["UrPerson1", "UrPerson2", "UrPerson3"]
    private static let travellerSize: CGFloat = 40
    private static let routeHeight: CGFloat = 76

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connector: IntroConnectorState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var start = Date()
    @State private var person = 0
    @State private var deck: [Int] = []
    @State private var tripCount = 0

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let trip = reduceMotion ? 0.9 : elapsed.truncatingRemainder(dividingBy: Self.tripSeconds) / Self.tripSeconds
            let count = reduceMotion ? 0 : Int(elapsed / Self.tripSeconds)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {

                    // the dashed route
                    Path { path in
                        path.move(to: CGPoint(x: 6, y: geometry.size.height / 2))
                        path.addLine(to: CGPoint(x: geometry.size.width - 6, y: geometry.size.height / 2))
                    }
                    .stroke(Color.urPink.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))

                    // the stops, painted over the line: you, the connector, the internet
                    HStack {
                        routeStop("You", color: .urLightBlue, leading: true)
                        Spacer()
                        ZStack {
                            if !connector.floating {
                                IntroConnectorMark()
                            }
                        }
                        .frame(width: introductionRouteConnectorSize, height: introductionRouteConnectorSize)
                        .introConnectorHero()
                        Spacer()
                        routeStop("Internet", color: .white, leading: false)
                    }

                    // the traveller, above the stops
                    traveller(trip: trip)
                        .frame(width: Self.travellerSize, height: Self.travellerSize)
                        .offset(x: (geometry.size.width - Self.travellerSize) * position(trip: trip))
                }
            }
            .onChange(of: count) { next in
                advance(to: next)
            }
        }
        .frame(height: Self.routeHeight)
        .accessibilityHidden(true)
        .onAppear {
            start = Date()
        }
    }

    // the docs keyframes: 1% -> 94% of the line, visible from 4% to 88%
    private func position(trip: Double) -> Double {
        reduceMotion ? 0.85 : 0.01 + 0.93 * trip
    }

    private func alpha(trip: Double) -> Double {
        if reduceMotion { return 1 }
        if trip < 0.04 { return trip / 0.04 }
        if trip > 0.94 { return 0 }
        if trip > 0.88 { return 1 - (trip - 0.88) / 0.06 }
        return 1
    }

    @ViewBuilder
    private func traveller(trip: Double) -> some View {
        // a little bounce in the step, so the trip reads as a walk, not a slide
        let bob = reduceMotion ? 0.0 : sin(trip * 2 * .pi * 9)
        let name = Self.people[person]
        ZStack {
            // the docs' drop-shadow(0 0 4px rgba(255,255,255,.3)), traced on the
            // tile's own connector outline: its silhouette, tinted white, drawn a
            // little larger a few times behind it
            ForEach(Array([0.10, 0.07, 0.05, 0.04, 0.03, 0.02].enumerated()), id: \.offset) { index, layerAlpha in
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .foregroundStyle(Color.white.opacity(layerAlpha))
                    .scaleEffect(1 + 0.035 * Double(index + 1))
            }
            Image(name)
                .resizable()
                .interpolation(.none)
        }
        .opacity(alpha(trip: trip))
        .offset(y: -2 * (bob + 1) / 2)
        .rotationEffect(.degrees(4 * bob))
    }

    private func routeStop(_ label: LocalizedStringKey, color: Color, leading: Bool) -> some View {
        Text(label)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(color.opacity(0.9))
            .padding(.leading, leading ? 0 : 8)
            .padding(.trailing, leading ? 8 : 0)
            .padding(.vertical, 2)
            .background(Color.urBlack)
    }

    /// A new person for each trip: the deck holds every person once, in a random order.
    private func advance(to count: Int) {
        guard count > tripCount else { return }
        tripCount = count
        if deck.isEmpty {
            deck = Self.people.indices.filter { $0 != person }.shuffled()
        }
        person = deck.removeFirst()
    }
}

#Preview {
    IntroTraveller()
        .padding()
        .background(Color.urBlack)
        .environmentObject(ThemeManager.shared)
        .environmentObject(IntroConnectorState())
}
