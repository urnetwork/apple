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
                let frame = proxy.frame(in: .named(IntroConnectorState.coordinateSpace))
                Color.clear
                    .onAppear { report(frame) }
                    .onChange(of: frame) { next in report(next) }
            }
        )
    }

    private func report(_ frame: CGRect) {
        guard let state, frame.width > 0 else { return }
        if hero {
            state.heroFrame = frame
        } else {
            state.headerFrame = frame
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.floating {
                IntroConnectorMark()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: state.inHeader) { inHeader in
            retarget(inHeader: inHeader)
        }
        .onChange(of: state.headerFrame) { _ in
            if state.inHeader {
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
            fly(to: target)
        } else if state.floating {
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
