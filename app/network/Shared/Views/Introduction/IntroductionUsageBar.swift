//
//  IntroductionUsageBar.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 10/1/25.
//

import SwiftUI

struct IntroductionUsageBar: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    
    let close: () -> Void
    let back: () -> Void
    let totalReferrals: Int
    let referralCode: String
    let meanReliabilityWeight: Double
    let continueAction: () -> Void
    
    var body: some View {
        
        GeometryReader { proxy in
        
            ScrollView {
            
                VStack(alignment: .leading, spacing: 0) {

                    IntroductionTopBar(step: 2, onSkip: close, onBack: back)

                    Spacer().frame(height: 16)
                    
                    Text("Your bandwidth")
                        .font(themeManager.currentTheme.titleFont)

                    Spacer().frame(height: 16)

                    Text("You get free data every day.")
                        .font(themeManager.currentTheme.bodyFontLarge)
                    
                    Spacer().frame(height: 32)
                    
                    UsageBar(
                        availableByteCount: subscriptionBalanceViewModel.availableByteCount,
                        pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
                        usedByteCount: subscriptionBalanceViewModel.usedBalanceByteCount,
                        meanReliabilityWeight: meanReliabilityWeight,
                        totalReferrals: totalReferrals,
                        dailyBalanceByteCount: subscriptionBalanceViewModel.startBalanceByteCount,
                        showReferrals: false
                    )

                    if subscriptionBalanceViewModel.startBalanceByteCount > 0 {

                        Spacer().frame(height: 32)

                        // the free allowance the server grants (pro.yml free.data per
                        // data_period), never a number typed into the app
                        Text("By default, you get \(formatDailyAllowance(subscriptionBalanceViewModel.startBalanceByteCount)) every day.")
                            .font(themeManager.currentTheme.bodyFont)
                    }
                    
                    Spacer(minLength: 24)
                    
                    VStack {
                     
                        Button(action: continueAction) {
                            Text("Next")
                                .font(themeManager.currentTheme.toolbarTitleFont.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.urElectricBlue)
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("acceptance.introduction.usage.continue")
                        
                    }
                    
                }
                .padding()
                .frame(minHeight: proxy.size.height)
            }
            
        }
        .navigationBarBackButtonHidden(true)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        
    }
}

/// The daily allowance for prose: whole gibibytes without decimals ("30 GiB"), anything else in the balance form.
func formatDailyAllowance(_ byteCount: Int) -> String {
    let gib = 1024 * 1024 * 1024
    if byteCount > 0 && byteCount % gib == 0 {
        return "\(byteCount / gib) GiB"
    }
    return formatBalanceBytes(byteCount)
}

#Preview {
    IntroductionUsageBar(
        close: {},
        back: {},
        totalReferrals: 4,
        referralCode: "ABC123",
        meanReliabilityWeight: 0.2,
        continueAction: {}
    )
    .environmentObject(ThemeManager.shared)
    .environmentObject(IntroConnectorState())
}
