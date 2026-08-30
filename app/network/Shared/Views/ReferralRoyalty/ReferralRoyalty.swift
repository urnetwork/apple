//
//  ReferralRoyalty.swift
//  URnetwork
//
//  The referral king-frog gold system, matching the ur.io referral panel:
//  the crowned frog mascot, a pulsing gold aura, the gold code pill and gold
//  gradient buttons. Used only for the referral celebration moments, so gold
//  here always reads as "referral royalty" (distinct from the Pro gold ring).
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The daily GiB each side of a verified referral earns, for life
/// (server pro.yml referral: bonus_per_referral / referred_bonus over 24h).
let referralBonusGiBPerDay = 3

/// The max referrals a network is paid for (pro.yml referral.max_referrals).
let referralMaxReferrals = 20

/**
 * The crowned frog, gently bobbing like on ur.io (translate + slight tilt).
 */
struct ReferralFrogView: View {

    var size: CGFloat = 108
    var bob: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bobbing = false

    var body: some View {
        Image("ReferralFrog")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(y: bobbing ? -5 : 0)
            .rotationEffect(.degrees(bobbing ? 1 : -1))
            .onAppear {
                guard bob && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    bobbing = true
                }
            }
    }
}

/**
 * Soft pulsing gold aura drawn behind its content.
 */
struct GoldAura<Content: View>: View {

    var size: CGFloat
    var pulseSeconds: Double = 5
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.urReferralGold.opacity(pulsing ? 0.26 : 0.15),
                            Color.urReferralGold.opacity(0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 2
                    )
                )
                .frame(width: size, height: size)
                .scaleEffect(pulsing ? 1.06 : 1.0)

            content
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: pulseSeconds / 2).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

/**
 * The referral code in a dark pill with a dashed gold border (the site's
 * code pill). Tapping copies the code.
 */
struct ReferralGoldCodePill: View {

    let code: String

    @State private var copied = false

    var body: some View {
        Button(action: {
            #if canImport(UIKit)
            UIPasteboard.general.string = code
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            #endif
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                copied = false
            }
        }) {
            HStack {
                Text(code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.urReferralGoldLight)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if copied {
                    Text("Copied!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.urReferralGoldLight)
                } else {
                    Image(systemName: "document.on.document")
                        .foregroundColor(.urReferralGoldLight)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.urReferralGold.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/**
 * Gold gradient capsule label for share buttons (the site's gold button).
 * Wrap it in a ShareLink / ReferralShareLink.
 */
struct GoldShareLabel: View {

    var body: some View {
        HStack {
            Spacer()

            Text("Share")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.urReferralGoldInk)

            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.urReferralGoldInk)

            Spacer()
        }
        .padding(.vertical, 13)
        .background(
            LinearGradient(
                colors: [.urReferralGoldPale, .urReferralGold],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(Capsule())
    }
}

/**
 * The "royal welcome" moment shown inside the referral sheets when a code is
 * accepted: frog in a gold aura plus confirmation copy.
 */
struct RoyalWelcomeContent: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .center) {

            GoldAura(size: 160, pulseSeconds: 3.4) {
                ReferralFrogView(size: 108)
            }

            Spacer().frame(height: 8)

            Text("A royal welcome!")
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundColor(.urReferralGoldLight)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 8)

            Text("Referral confirmed — you and your friend each get +\(referralBonusGiBPerDay) GiB/day of free data, for life.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/**
 * Small gold confirmation chip shown in the signup forms once a referral
 * code has been applied.
 */
struct ReferralAppliedChip: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack {
            ReferralFrogView(size: 24, bob: false)

            Spacer().frame(width: 8)

            Text("Referral Bonus applied")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(.urReferralGoldLight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.urReferralGold.opacity(0.12))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.urReferralGold.opacity(0.4), lineWidth: 1)
        )
    }
}

/**
 * One-time crowning celebration for the referrer: shown the first time a
 * friend joins with their code (later referrals get the gold snackbar).
 */
struct ReferralCelebrationOverlay: View {

    let joinedCount: Int
    let referralCode: String?
    let referralLinkViewModel: ReferralLinkViewModel
    let onDismiss: () -> Void

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ZStack {

            Color.urBlack
                .ignoresSafeArea()
                // absorb touches so taps cannot fall through to the screen
                // behind the overlay
                .onTapGesture {}

            ScrollView {
                VStack(alignment: .center) {

                    Spacer().frame(height: 48)

                    GoldAura(size: 240, pulseSeconds: 3.4) {
                        ReferralFrogView(size: 144)
                    }

                    Spacer().frame(height: 16)

                    Text("You're referral royalty!")
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(.urReferralGoldLight)
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 16)

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%1$lld friends just joined URnetwork with your code. Each one earns you +%2$lld GiB a day of free data — for life."),
                            joinedCount,
                            referralBonusGiBPerDay
                        )
                    )
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .multilineTextAlignment(.center)

                    Spacer().frame(height: 32)

                    if let referralCode = referralCode, !referralCode.isEmpty {

                        ReferralGoldCodePill(code: referralCode)

                        Spacer().frame(height: 16)

                        ReferralShareLink(referralLinkViewModel: referralLinkViewModel) {
                            GoldShareLabel()
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { onDismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()
            }
        }
    }
}

/**
 * The refer-friends panel in the referral king-frog gold theme, matching the
 * ur.io referral panel. Once the network has referrals the panel is crowned:
 * royal heading, crown line and a faster gold pulse.
 */
struct ReferSheet: View {

    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    let dismiss: () -> Void

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {

        let totalReferrals = referralLinkViewModel.totalReferrals
        let crowned = totalReferrals > 0

        ZStack {

            Color.urBlack
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .center) {

                    GoldAura(size: 200, pulseSeconds: crowned ? 3.4 : 5) {
                        ReferralFrogView(size: 120)
                    }

                    Spacer().frame(height: 16)

                    if crowned {
                        Text("You're referral royalty!")
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(.urReferralGoldLight)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Refer friends")
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(.urReferralGoldLight)
                            .multilineTextAlignment(.center)
                    }

                    Spacer().frame(height: 16)

                    Text("More connections help our community stay anonymous (and help you earn!)")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .multilineTextAlignment(.center)

                    if crowned {

                        Spacer().frame(height: 12)

                        HStack {
                            Text("👑")

                            Text(
                                String.localizedStringWithFormat(
                                    String(localized: "%1$lld friends have joined — you're earning +%2$lld GiB/day, for life."),
                                    totalReferrals,
                                    min(totalReferrals, referralMaxReferrals) * referralBonusGiBPerDay
                                )
                            )
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(.urReferralGoldLight)
                        }
                        .multilineTextAlignment(.center)
                    }

                    Spacer().frame(height: 32)

                    if let referralCode = referralLinkViewModel.referralCode, !referralCode.isEmpty {

                        // referrals no longer use deep links; friends enter
                        // the code when they sign up
                        Text("Share your code. Friends enter it when they sign up.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .multilineTextAlignment(.center)

                        Spacer().frame(height: 12)

                        ReferralGoldCodePill(code: referralCode)

                        Spacer().frame(height: 16)

                        ReferralShareLink(referralLinkViewModel: referralLinkViewModel) {
                            GoldShareLabel()
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding(24)
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()
            }
        }
    }
}
