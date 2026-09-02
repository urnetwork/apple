//
//  IntroductionTopBar.swift
//  URnetwork
//
//  The shared top bar of the post-login onboarding flow: back after the
//  first page, the step bubbles in the middle so the user always sees where
//  they are and how much is left, and a small muted Skip at the far end that
//  leaves the whole flow at any point, so nobody feels captive.
//

import SwiftUI

/// The pages of the onboarding flow, in order (welcome, data, providing, referral, quick connect).
let introductionStepCount = 5

/// The connector mark's size in the header; the mark itself is about two thirds of it (icon safe zone).
let introductionHeaderConnectorSize: CGFloat = 34

/**
 * One bubble per step: the current step is a white pill, earlier steps are
 * dimmed white, later steps are faint. Read to accessibility as "Step 2 of 5".
 */
struct IntroductionStepBubbles: View {

    let step: Int
    var totalSteps: Int = introductionStepCount

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...totalSteps, id: \.self) { index in
                Capsule()
                    .fill(color(index))
                    .frame(width: index == step ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: String(localized: "Step %lld of %lld"), step, totalSteps))
    }

    private func color(_ index: Int) -> Color {
        if index == step {
            return .white
        }
        if index < step {
            return Color.white.opacity(0.55)
        }
        return themeManager.currentTheme.textFaintColor
    }
}

/**
 * Back (after page 1), the bubbles with the connector's header slot beside
 * them (after page 1), and Skip.
 */
struct IntroductionTopBar: View {

    let step: Int
    let onSkip: () -> Void
    var onBack: (() -> Void)? = nil

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ZStack {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.textColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }

                Spacer()

                Button(action: onSkip) {
                    Text("Skip")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .padding(.horizontal, 8)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("acceptance.introduction.skip")
            }

            HStack(spacing: 10) {
                if step > 1 {
                    // the connector lands here from page 1's route line
                    Color.clear
                        .frame(width: introductionHeaderConnectorSize, height: introductionHeaderConnectorSize)
                        .introConnectorHeaderSlot()
                }
                IntroductionStepBubbles(step: step)
            }
        }
        .frame(height: 44)
    }
}

#Preview {
    VStack {
        IntroductionTopBar(step: 1, onSkip: {})
        IntroductionTopBar(step: 3, onSkip: {}, onBack: {})
    }
    .padding()
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
    .environmentObject(IntroConnectorState())
}
