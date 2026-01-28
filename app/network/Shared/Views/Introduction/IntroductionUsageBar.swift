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
    let totalReferrals: Int
    let referralCode: String
    let meanReliabilityWeight: Double
    
    var body: some View {
        
        GeometryReader { proxy in
        
            ScrollView {
            
                VStack(alignment: .leading) {
                    
                    IntroIcon()
                    
                    Text("Boost Your Bandwidth - Earn More Every Day")
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 16)
                    
                    Text("By participating in the network and providing bandwidth you can earn rewards.")
                        .font(themeManager.currentTheme.bodyFontLarge)
                    
                    Spacer().frame(height: 32)
                    
                    UsageBar(
                        availableByteCount: subscriptionBalanceViewModel.availableByteCount,
                        pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
                        usedByteCount: subscriptionBalanceViewModel.usedBalanceByteCount,
                        meanReliabilityWeight: meanReliabilityWeight,
                        totalReferrals: totalReferrals,
                        dailyBalanceByteCount: subscriptionBalanceViewModel.startBalanceByteCount
                    )
                    
                    Spacer().frame(height: 32)
                    
                    Text("By default you get 10 GiB/month. Here's how you can earn extra bandwidth:")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 16)
                    
                    IntroBulletPoint(text: "Stay connected daily = Earn up to 100 GiB/Day")
                    
                    IntroBulletPoint(text: "Refer a friend = +30 GiB/Month")
                    
                    Spacer()
                    
                    VStack {
                     
                        NavigationLink(destination: IntroductionParticipateSettingsView(
                            close: close,
                            totalReferrals: totalReferrals,
                            referralCode: referralCode,
                            meanReliabilityWeight: meanReliabilityWeight
                        )) {
                            Text("Continue")
                                .font(themeManager.currentTheme.toolbarTitleFont.bold())
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.urElectricBlue)
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                    }
                    
                }
                .padding()
                .frame(minHeight: proxy.size.height)
            }
            
        }
        
    }
}

#Preview {
    IntroductionUsageBar(
        close: {},
        totalReferrals: 4,
        referralCode: "ABC123",
        meanReliabilityWeight: 0.2
    )
}
