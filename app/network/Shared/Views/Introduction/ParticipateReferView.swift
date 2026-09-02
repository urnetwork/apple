//
//  ParticipateRefer.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI

struct ParticipateReferView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let close: () -> Void
    let back: () -> Void
    let totalReferrals: Int
    let referralCode: String
    var terms: ReferralTerms = .default
    let continueAction: () -> Void
    
    var body: some View {
        
        GeometryReader { proxy in
            
            ScrollView {
                
                VStack(alignment: .leading, spacing: 0) {

                    IntroductionTopBar(step: 4, onSkip: close, onBack: back)

                    Spacer().frame(height: 16)
                    
                    Text("Refer friends")
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 16)
                    
                    Text("When you refer a friend:")
                        .font(themeManager.currentTheme.bodyFontLarge)
                    
                    Spacer().frame(height: 16)
                    
                    IntroBulletPoint(text: "You get +\(terms.bonusGiBPerDay) GiB/day for life")

                    IntroBulletPoint(text: "Your friend gets +\(terms.referredBonusGiBPerDay) GiB/day for life")
                    
                    Spacer().frame(height: 16)
                    
                    VStack {
                     
                        HStack {
                            
                            Text("Refer friends")
                                .font(themeManager.currentTheme.toolbarTitleFont)
                            
                            Spacer()
                            
                            Text(verbatim: "\(totalReferrals)/\(terms.maxReferrals)")
                                .font(themeManager.currentTheme.toolbarTitleFont)
                            
                        }
                        
                        Spacer().frame(height: 8)
                        
                        ReferBar(referralCount: totalReferrals, total: terms.maxReferrals)
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(16)
                    
                    Spacer().frame(height: 24)

                    ReferralGoldPanel(
                        referralCode: referralCode,
                        totalReferrals: totalReferrals,
                        terms: terms
                    )
                    
                    Spacer(minLength: 24)
                    
                    UrButton(text: "Next", action: continueAction)
                    .accessibilityIdentifier("acceptance.introduction.refer.continue")
                    
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

#Preview {
    ParticipateReferView(
        close: {},
        back: {},
        totalReferrals: 2,
        referralCode: "TZ1TJX",
        continueAction: {}
    )
    .environmentObject(ThemeManager.shared)
    .environmentObject(IntroConnectorState())
}
