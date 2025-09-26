//
//  IntroductionView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI

struct IntroductionView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let close: () -> Void
    
    var body: some View {
        
        NavigationStack {
            
            ScrollView {
                
                VStack(alignment: .leading) {
                    
                    Text("Welcome to URnetwork")
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 16)
                    
                    Text("URnetwork is the most local and most private network on the planet. With over 20x usable cities of other leading VPNs, and 100x fewer users per IP address. Unlock all the fun in the world and all the privacy without compromises.")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 32)
                    
                    /**
                     * Upgrade prompt
                     */
                    VStack(alignment: .leading) {
                        
                        Text("Upgrade")
                            .font(themeManager.currentTheme.toolbarTitleFont)
                        
                        Spacer().frame(height: 4)
                        
                        Text("Get unlimited access to the full network and features on all platforms")
                            .font(themeManager.currentTheme.bodyFont)
                        
                        Spacer().frame(height: 16)
                        
                        // todo - pull this amount
                        UrButton(text: "$5/month", action: {})
                        
                        // todo - implement yearly
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(16)
                    
                    Spacer().frame(height: 16)
                    
                    HStack {
                        Spacer()
                        Text("or")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        Spacer()
                    }
                    
                    Spacer().frame(height: 16)
                    
                    
                    
                    /**
                     * Participate prompt
                     */
                    VStack(alignment: .leading) {
                        
                        Text("Participate in the network and get free access to the communtiy edition.")
                            // .font(themeManager.currentTheme.bodyFont)
                            .font(themeManager.currentTheme.toolbarTitleFont)
                        
                        Spacer().frame(height: 4)
                        
                        Text("URnetwork is powered by a patented protocol that keeps everyone safe and secure.")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                        
                        Spacer().frame(height: 16)
                        
                        NavigationLink(destination: IntroductionParticipateSettingsView(close: close)) {
                            Text("Get connected")
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
}

#Preview {
    IntroductionView(
        close: {}
    )
}
