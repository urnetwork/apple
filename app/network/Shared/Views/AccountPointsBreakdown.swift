//
//  AccountPointsBreakdown.swift
//  URnetwork
//
//  The points headline of the Earnings screen: the total earned, the
//  providing / referral / reliability breakdown and the Seeker multiplier
//  row. Points are URnetwork's own system and never depend on a wallet.
//

import SwiftUI

struct AccountPointsBreakdown: View {

    @EnvironmentObject var themeManager: ThemeManager

    var netPoints: Double
    var providingPoints: Double
    var referralPoints: Double
    var multiplierPoints: Double
    var reliabilityPoints: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            UrLabel(text: "Points earned")
            Text(verbatim: SnAlpha.formatPoints(netPoints))
                .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                .foregroundColor(themeManager.currentTheme.textColor)
                .padding(.bottom, -4)

            Spacer().frame(height: 16)
            Divider()
            Spacer().frame(height: 12)

            HStack {
                column("Providing", providingPoints)
                Spacer()
                column("Referral", referralPoints)
                Spacer()
                column("Reliability", reliabilityPoints)
            }

            if multiplierPoints > 0 {
                Spacer().frame(height: 12)
                Divider()
                Spacer().frame(height: 12)
                HStack(alignment: .center) {
                    Image("2x")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                    Spacer().frame(width: 16)
                    VStack(alignment: .leading) {
                        Text("Seeker Token Verified!")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                        Text("The Seeker multiplier applies to points only.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    Spacer()
                    Text(verbatim: "+\(SnAlpha.formatPoints(multiplierPoints))")
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private func column(_ label: LocalizedStringKey, _ points: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            UrLabel(text: label)
            Text(verbatim: SnAlpha.formatPoints(points))
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundColor(themeManager.currentTheme.textColor)
        }
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    AccountPointsBreakdown(
        netPoints: 12_345.5,
        providingPoints: 9_000,
        referralPoints: 2_000,
        multiplierPoints: 345.5,
        reliabilityPoints: 1_000
    )
    .environmentObject(themeManager)
    .padding()
    .background(themeManager.currentTheme.backgroundColor)
}
