//
//  UsageBar.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/24/25.
//

import SwiftUI
import Charts

struct DailyDataUsage: Identifiable {
    
    var name: String
    var bytes: Int
    
    var id = UUID()
}

struct UsageBar: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let data: [DailyDataUsage]
    let totalBytes: Int
    let meanReliabilityWeight: Double
    let totalReferrals: Int
    let cappedReliabilityData: Double
    let dailyBalanceByteCount: Int
    // when set, the referral row is a share link that opens the referral flow
    let referralCode: String?
    // the referral row; off where referrals have their own screen
    let showReferrals: Bool
    // the referral cap and bonus, from the server
    let terms: ReferralTerms

    init(
        availableByteCount: Int,
        pendingByteCount: Int,
        usedByteCount: Int,
        meanReliabilityWeight: Double,
        totalReferrals: Int,
        dailyBalanceByteCount: Int,
        referralCode: String? = nil,
        showReferrals: Bool = true,
        terms: ReferralTerms = .default
    ) {
        // the series names are also the chart legend labels, so they localize;
        // they must match the chartForegroundStyleScale keys below exactly
        self.data = [
            .init(name: String(localized: "Used"), bytes: usedByteCount),
            .init(name: String(localized: "Pending"), bytes: pendingByteCount),
            .init(name: String(localized: "Available"), bytes: availableByteCount),
        ]
        self.totalBytes = availableByteCount + pendingByteCount + usedByteCount
        
        self.meanReliabilityWeight = meanReliabilityWeight
        self.totalReferrals = totalReferrals
        
        cappedReliabilityData = min(meanReliabilityWeight * 100, 100)
        self.dailyBalanceByteCount = dailyBalanceByteCount
        self.referralCode = referralCode
        self.showReferrals = showReferrals
        self.terms = terms
    }
    
    func minNonZeroValue(_ bytes: Int) -> Int {
        
        let minVal = Double(self.totalBytes) * 0.015 // enforce 1.5% so it shows up in the bar
        
        if bytes < Int(minVal) {
            // ensure it takes up min % of bar
            return Int(minVal)
        } else {
            // larger than min value, display as is
            return bytes
        }

        
    }
    
    func getCornerRadii(_ index: Int) -> RectangleCornerRadii {
        
        // handle leading
        if index == 0 {
            // we already checked it's not a full bar
            // round only leading
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
            
        }
        
        // handle trailing
        if index == (data.count - 1) {
            // not a full bar
            // round only trailing
            return RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: 0,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        
        }
        
        // handle pending
        return RectangleCornerRadii(
            topLeading: 0,
            bottomLeading: 0,
            bottomTrailing: self.data[data.count - 1].bytes == 0 ? cornerRadius : 0, // round if available is 0
            topTrailing: self.data[data.count - 1].bytes == 0 ? cornerRadius : 0, // round if available is 0
        )
        
    }
    
    let cornerRadius: CGFloat = 12
    
    var body: some View {
        
        VStack(alignment: .leading) {
         
            Chart(data.indices, id: \.self) { index in
                   
                BarMark(
                    x: .value("Data", self.minNonZeroValue(data[index].bytes))
                )
                .foregroundStyle(by: .value("Name", data[index].name))
                .clipShape(
                    UnevenRoundedRectangle(
                        cornerRadii: getCornerRadii(index)
                    )
                )
                
            }
            .chartXAxis(.hidden)
            .frame(height: 32)
            .chartForegroundStyleScale([
                String(localized: "Used"): Color.urElectricBlue,
                String(localized: "Pending"): Color.urCoral,
                String(localized: "Available"): themeManager.currentTheme.textFaintColor,
            ])
            
            Spacer().frame(height: 16)
            
            HStack {
                
                Text("Daily Data Balance:")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                
                Spacer()
                
                Text(formatBalanceBytes(dailyBalanceByteCount))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                
            }
            
            if showReferrals {

            Divider()
            
            Spacer().frame(height: 8)

            /**
             * referrals. tapping shares the referral link, to make it easy to
             * refer people from anywhere the bar is shown
             */
            if let referralCode = referralCode {
                ShareLink(
                    item: referralShareMessage(referralCode),
                    subject: Text("URnetwork Referral Code")
                ) {
                    referralRow(showsShareIcon: true)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } else {
                referralRow(showsShareIcon: false)
            }

            }

        }

    }

    private func referralShareMessage(_ code: String) -> String {
        // referrals no longer use deep links; friends enter the code on sign up.
        // share a generic invite until the code loads (see ReferralShareLink)
        if !code.isEmpty {
            return String(localized: "Join me on URnetwork! Get the app and enter referral code \(code) when you sign up.")
        }
        return String(localized: "Join me on URnetwork! Get the app and enter my referral code when you sign up.")
    }

    private func referralRow(showsShareIcon: Bool) -> some View {
        HStack {

            // real plural rules live in Localizable.xcstrings
            // ("Total referrals: %lld")
            Text("Total referrals: \(totalReferrals)")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)

            Spacer()

            Text("+\(terms.earnedGiBPerDay(totalReferrals)) GiB/Day")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundStyle(themeManager.currentTheme.textMutedColor)

            if showsShareIcon {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
            }

        }
    }

}

#Preview {
    UsageBar(
        availableByteCount: 70,
        pendingByteCount: 10,
        usedByteCount: 20,
        meanReliabilityWeight: 0.2,
        totalReferrals: 2,
        dailyBalanceByteCount: 100
    )
}
