//
//  AccountPointsBreakdown.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 6/24/25.
//

import SwiftUI

struct AccountPointsBreakdown: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var isSeekerOrSagaHolder: Bool
    var netPoints: Double
    var payoutPoints: Double
    var referralPoints: Double
    var multiplierPoints: Double
    
    var body: some View {
        
        VStack(spacing: 0) {

            HStack {
                Text("Points breakdown")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                Spacer()
            }

            Spacer().frame(height: 12)

            HStack {

                VStack {
                    HStack {
                        UrLabel(text: "Payout")
                        Spacer()
                    }

                    HStack {
                        Text(payoutPoints.formatted(.number.grouping(.automatic)))
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(themeManager.currentTheme.textColor)

                        Spacer()
                    }
                }

                Spacer()

                VStack {
                    HStack {
                        UrLabel(text: "Referral")
                        Spacer()
                    }

                    HStack {
                        Text(referralPoints.formatted(.number.grouping(.automatic)))
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(themeManager.currentTheme.textColor)

                        Spacer()
                    }
                }
                
                Spacer()
                
                VStack {
                    HStack {
                        UrLabel(text: "Reliability")
                        Spacer()
                    }

                    HStack {
                        Text("0")
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(themeManager.currentTheme.textColor)

                        Spacer()
                    }
                }

            }

            Spacer().frame(height: 8)

            Divider()

            Spacer().frame(height: 16)
            
            if isSeekerOrSagaHolder {
                
                VStack(spacing: 0) {
                 
                    HStack(alignment: .center) {

                        Image("2x")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)

                        Spacer().frame(width: 16)

                        VStack(alignment: .leading) {
                            
                            Text("Seeker Token Verified!")
                                .font(themeManager.currentTheme.bodyFont)
                            
                            Text("You're earning 2x points")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                            
                        }

                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 0) {
                         
                            Text("+\(multiplierPoints.formatted(.number.grouping(.automatic)))")
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.textColor)

                        }
                        
                    }
     
                }
                
                Spacer().frame(height: 16)

            }

            HStack {
                Spacer()
                
                VStack(alignment: .trailing, spacing: 0) {
                 
                    Text(netPoints.formatted(.number.grouping(.automatic)))
                        .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                        // .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .padding(.bottom, -4)
                        
                    Text("Net points earned")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        
                    
                }
                
            }

        }
        .padding()
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
        // .padding()
        
    }
}

//#Preview {
//    AccountPointsBreakdown()
//}
