//
//  ReferralGoldPanel.swift
//  URnetwork
//
//  The ur.io referral panel (react/src/components/ReferralPanel.jsx, its
//  narrow layout) in SwiftUI: a gold-washed rounded surface with a pulsing
//  aura, the bobbing king frog, kicker / heading / detail copy, the dashed
//  code pill with its gold copy button, a gold share button and a status
//  line. Once the network has a referral the panel is crowned: royal heading,
//  brighter border, faster pulse and the crown line. Shown on the onboarding
//  referral page.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ReferralGoldPanel: View {

    let referralCode: String
    let totalReferrals: Int
    var terms: ReferralTerms = .default

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var crowned: Bool { totalReferrals > 0 }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {

            ReferralFrogView(size: 108)

            Spacer().frame(height: 18)

            Text("Referrals")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .bold))
                .kerning(1.5)
                .foregroundColor(.urReferralGold)

            Spacer().frame(height: 6)

            Group {
                if crowned {
                    Text("You're referral royalty!")
                } else {
                    Text("Refer a friend and you both get free data")
                }
            }
            .font(Font.custom("PP NeueBit", size: 24).weight(.bold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)

            Spacer().frame(height: 6)

            Text("Every verified referral gives each of you \(terms.bonusGiBPerDay) GiB/day for free, for life.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(Color.urLightBlue.opacity(0.85))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 18)

            if !referralCode.isEmpty {

                Text("Your referral code")
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1)
                    .foregroundColor(Color.urLightBlue.opacity(0.6))

                Spacer().frame(height: 8)

                ReferralGoldCodeCopyPill(code: referralCode)

                Spacer().frame(height: 12)

                ShareLink(
                    item: String(localized: "Join me on URnetwork! Get the app and enter referral code \(referralCode) when you sign up."),
                    subject: Text("URnetwork Referral Code")
                ) {
                    GoldShareLabel()
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .tint(.urReferralGoldLight)
            }

            Spacer().frame(height: 16)

            if crowned {
                HStack(spacing: 8) {
                    Text("👑")
                        .font(.system(size: 18))
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%1$lld friends have joined — you're earning +%2$lld GiB/day, for life."),
                            totalReferrals,
                            terms.earnedGiBPerDay(totalReferrals)
                        )
                    )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.urReferralGoldLight)
                }
                .multilineTextAlignment(.center)
            } else {
                Text("No friends yet. Share your code and watch the crown appear. 👑")
                    .font(.system(size: 13))
                    .foregroundColor(Color.urLightBlue.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(ReferralGoldPanelBackground(crowned: crowned))
    }
}

/// The panel's ground: the site's gold wash, the pulsing aura and the gold border.
private struct ReferralGoldPanelBackground: View {

    let crowned: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        ZStack {
            shape.fill(Color.urBlack)
            shape.fill(Color.urReferralGold.opacity(0.04))
            shape.fill(
                RadialGradient(
                    colors: [Color.urReferralGold.opacity(0.16), Color.urReferralGold.opacity(0)],
                    center: UnitPoint(x: 0.12, y: 0),
                    startRadius: 0,
                    endRadius: 520
                )
            )
            // the site's aura: opacity .55 -> .9 and scale 1 -> 1.06 over 5s (3.4s crowned)
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let period = crowned ? 3.4 : 5.0
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(t / period * 2 * .pi)
                shape.fill(
                    RadialGradient(
                        colors: [
                            Color.urReferralGold.opacity(0.22 * (0.55 + 0.35 * pulse)),
                            Color.urReferralGold.opacity(0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 360 * (1 + 0.06 * pulse)
                    )
                )
            }
            shape.strokeBorder(Color.urReferralGold.opacity(crowned ? 0.75 : 0.4), lineWidth: 1)
        }
        .shadow(color: Color.urReferralGold.opacity(0.35), radius: 24, y: 8)
    }
}

/**
 * The site's code pill: the code in a dark dashed-gold pill with the gold
 * gradient Copy button inside it. Tapping either copies; the button turns
 * green and reads "Copied!" for a moment.
 */
struct ReferralGoldCodeCopyPill: View {

    let code: String

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 10) {
                Text(code)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.urReferralGoldLight)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                HStack(spacing: 7) {
                    Image(systemName: copied ? "checkmark" : "document.on.document")
                        .font(.system(size: 12, weight: .bold))
                    if copied {
                        Text("Copied!")
                    } else {
                        Text("Copy")
                    }
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(copied ? Color(red: 0.03, green: 0.14, blue: 0.06) : .urReferralGoldInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: copied
                            ? [Color(red: 0.72, green: 0.97, blue: 0.78), .urGreen]
                            : [.urReferralGoldPale, .urReferralGold],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule()
                )
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.35), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    Color.urReferralGold.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copy() {
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
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            ReferralGoldPanel(referralCode: "TZ1TJX", totalReferrals: 0)
            ReferralGoldPanel(referralCode: "TZ1TJX", totalReferrals: 4)
        }
        .padding()
    }
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
}
