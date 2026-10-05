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
    // the referral row's figures, which wait for the referral read
    let referralLine: ReferralBonusLine
    let cappedReliabilityData: Double
    let dailyBalanceByteCount: Int
    // when set, the referral row is a tap target that opens the one Referrals
    // screen (the Account section's); there is no separate referral flow
    let openReferrals: (() -> Void)?
    // the referral row; off where referrals have their own screen
    let showReferrals: Bool
    // when set, an info button by the daily balance opens the "About your
    // data" sheet (DataInfoSheet)
    let openDataInfo: (() -> Void)?

    init(
        availableByteCount: Int,
        pendingByteCount: Int,
        usedByteCount: Int,
        meanReliabilityWeight: Double,
        referralLine: ReferralBonusLine = .unavailable,
        dailyBalanceByteCount: Int,
        openReferrals: (() -> Void)? = nil,
        showReferrals: Bool = true,
        openDataInfo: (() -> Void)? = nil
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
        self.referralLine = referralLine
        
        cappedReliabilityData = min(meanReliabilityWeight * 100, 100)
        self.dailyBalanceByteCount = dailyBalanceByteCount
        self.openReferrals = openReferrals
        self.openDataInfo = openDataInfo
        self.showReferrals = showReferrals
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

                if let openDataInfo = openDataInfo {
                    Button(action: openDataInfo) {
                        Image(systemName: "info.circle")
                            .imageScale(.small)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About your data")
                    .accessibilityIdentifier("acceptance.usageBar.dataInfo")
                }
                
                Spacer()
                
                Text(formatBalanceBytes(dailyBalanceByteCount))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                
            }
            
            if showReferrals {

            Divider()
            
            Spacer().frame(height: 8)

            /**
             * referrals. tapping opens the Referrals screen, the same one the
             * Account section shows, so every entry point lands on one design
             */
            if let openReferrals = openReferrals {
                Button(action: openReferrals) {
                    referralRow(showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                referralRow(showsChevron: false)
            }

            }

        }

    }

    private func referralRow(showsChevron: Bool) -> some View {
        HStack {

            switch referralLine {
            case .earned(let totalReferrals, let gibPerDay):
                // real plural rules live in Localizable.xcstrings
                // ("Total referrals: %lld")
                Text("Total referrals: \(totalReferrals)")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)

                Spacer()

                Text("+\(gibPerDay) GiB/Day")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
            case .loading:
                Text("Total referrals")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)

                Spacer()

                // the count is not known yet: not "+0"
                ProgressView()
                    .controlSize(.mini)
            case .unavailable:
                // a failed read is not "+0"; the Referrals screen it opens
                // offers a retry
                Text("Total referrals")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundStyle(themeManager.currentTheme.textMutedColor)

                Spacer()
            }

            if showsChevron {
                Image(systemName: "chevron.right")
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
        referralLine: .earned(totalReferrals: 2, gibPerDay: 6),
        dailyBalanceByteCount: 100
    )
}
