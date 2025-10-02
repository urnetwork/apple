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
        
        ScrollView {
            
            VStack(alignment: .leading) {
             
                Text("Get URnetwork free for life by participating")
                    .font(themeManager.currentTheme.titleFont)
                
                VStack(alignment: .leading) {
                    
                    Text("Data usage")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    
                    Spacer().frame(height: 4)
                 
                    UsageBar(
                        availableByteCount: subscriptionBalanceViewModel.availableByteCount,
                        pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
                        usedByteCount: subscriptionBalanceViewModel.usedBalanceByteCount,
                        meanReliabilityWeight: meanReliabilityWeight,
                        totalReferrals: totalReferrals
                    )
                    
                    Spacer().frame(height: 8)
                    
                    Text("This bar in the app shows you how much free data you are earning from your provider. You can check in any time and adjust your settings to maximize your earnings.")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 16)
                    
                    Divider()
                    
                    Spacer().frame(height: 16)
                    
                    NavigationLink(destination: IntroductionParticipateSettingsView(
                        close: close,
                        totalReferrals: totalReferrals,
                        referralCode: referralCode,
                        meanReliabilityWeight: meanReliabilityWeight
                    )) {
                        Text("Next Step")
                            .font(themeManager.currentTheme.toolbarTitleFont.bold())
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.urElectricBlue)
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                }
                .padding()
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(16)
                
                Spacer()
                
            }
            .padding()
            
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
