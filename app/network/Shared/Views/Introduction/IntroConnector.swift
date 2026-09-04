//
//  IntroConnector.swift
//  URnetwork
//
//  The connector mark of the onboarding flow lives in one place and moves:
//  large in page 1's route line, small next to the step bubbles on every
//  later page. The two slots report their frames here; the host draws the
//  mark and flies it between them, so the pages after the first give the
//  icon's vertical room back to their content.
//

import SwiftUI

@MainActor
final class IntroConnectorState: ObservableObject {

    /// the coordinate space the slots and the overlay share
    static let coordinateSpace = "introduction"

    /// page 1's route slot
    @Published var heroFrame: CGRect? = nil
    /// the top bar's slot on later pages
    @Published var headerFrame: CGRect? = nil
    /// true once the flow has left page 1
    @Published var inHeader = false
    /// true while the host draws the mark; page 1's route draws its own otherwise, under the traveller
    @Published var floating = false
}

private struct IntroConnectorKey: EnvironmentKey {
    static let defaultValue: IntroConnectorState? = nil
}

extension EnvironmentValues {
    var introConnector: IntroConnectorState? {
        get { self[IntroConnectorKey.self] }
        set { self[IntroConnectorKey.self] = newValue }
    }
}

private struct IntroConnectorSlotModifier: ViewModifier {

    let hero: Bool

    @Environment(\.introConnector) private var state

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                // window space on purpose: the step pages are pushed by a
                // NavigationStack, where the host's named coordinate space is not
                // reachable, so a named lookup silently fell back to the window
                // space while the overlay positioned in its own inset space —
                // the mark landed one safe-area inset too low. Both sides now
                // speak window coordinates.
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { report(frame) }
                    .onChange(of: frame) { next in report(next) }
            }
        )
    }

    private func report(_ frame: CGRect) {
        guard let state, frame.width > 0 else { return }
        // onAppear re-reports the same frame after a rebuild; publish only a change
        if hero {
            if state.heroFrame != frame { state.heroFrame = frame }
        } else {
            if state.headerFrame != frame { state.headerFrame = frame }
        }
    }
}

extension View {
    /// Page 1's route slot: reports its frame to the host.
    func introConnectorHero() -> some View {
        modifier(IntroConnectorSlotModifier(hero: true))
    }

    /// The top bar's slot next to the step bubbles: reports its frame to the host.
    func introConnectorHeaderSlot() -> some View {
        modifier(IntroConnectorSlotModifier(hero: false))
    }
}

/// The connector mark on a black ground, which also masks the route line behind it.
struct IntroConnectorMark: View {
    var body: some View {
        Image("Icon")
            .resizable()
            .scaledToFit()
            .background(Color.urBlack)
    }
}

/**
 * The flying mark, drawn over the intro pages by the host. Parked (and
 * hidden) on the route slot while page 1 shows; on leaving page 1 it appears
 * there and flies into the header; on coming back it flies down and hands
 * the mark back to the route.
 */
struct FloatingIntroConnector: View {

    @ObservedObject var state: IntroConnectorState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: CGRect = .zero

    // the overlay's own window-space origin, subtracted from the window-space
    // slot frames so the mark lands on the slot whatever inset the host has
    @State private var origin: CGPoint = .zero
    // true once the mark has settled on the header slot; from then on a slot
    // that moves (the page scrolls) is followed by a snap, not a new flight
    @State private var settledInHeader = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if state.floating {
                    IntroConnectorMark()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { origin = proxy.frame(in: .global).origin }
            .onChange(of: proxy.frame(in: .global).origin) { next in
                if origin != next { origin = next }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: state.inHeader) { inHeader in
            retarget(inHeader: inHeader)
        }
        .onChange(of: state.headerFrame) { target in
            guard state.inHeader, let target else { return }
            if settledInHeader {
                // the header slot moved with its page; keep the mark on it
                frame = target
            } else {
                retarget(inHeader: true)
            }
        }
        .onChange(of: state.heroFrame) { hero in
            // stay parked on the route slot while page 1 draws its own mark
            if !state.floating, let hero {
                frame = hero
            }
        }
    }

    private func retarget(inHeader: Bool) {
        if inHeader {
            guard let target = state.headerFrame else { return }
            if !state.floating {
                if let hero = state.heroFrame {
                    frame = hero
                }
                state.floating = true
            }
            fly(to: target) {
                settledInHeader = true
            }
        } else if state.floating {
            settledInHeader = false
            guard let target = state.heroFrame else { return }
            fly(to: target) {
                state.floating = false
            }
        }
    }

    private func fly(to target: CGRect, completion: (() -> Void)? = nil) {
        if reduceMotion {
            frame = target
            completion?()
            return
        }
        withAnimation(.easeInOut(duration: 0.52)) {
            frame = target
        }
        if let completion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.56) {
                completion()
            }
        }
    }
}
