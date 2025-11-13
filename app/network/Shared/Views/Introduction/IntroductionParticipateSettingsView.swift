//
//  IntroductionParticipateSettings.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI

struct IntroductionParticipateSettingsView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    let close: () -> Void
    let totalReferrals: Int
    let referralCode: String
    let meanReliabilityWeight: Double
    
    var body: some View {
        
        GeometryReader { proxy in
            
            ScrollView {
                
                VStack(alignment: .leading) {
                    
                    IntroIcon()
                    
                    Text("Reliability Settings")
                        .font(themeManager.currentTheme.titleFont)
                    
                    Spacer().frame(height: 16)
                    
                    Text("Adjust settings to maximize reliability. App runs in the background when connected and on Wi-Fi. Reliability is how many IPs you make continually available to the network")
                        .font(themeManager.currentTheme.bodyFontLarge)
                    
                    Spacer().frame(height: 32)
                    
                    Text("You can adjust the setting to Always to fill the free data faster.")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 4)
                    
                    HStack {
                        ProvideControlPicker()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(
                        Rectangle()
                            .fill(themeManager.currentTheme.tintedBackgroundBase)
                            .overlay(
                                Rectangle()
                                    .fill(Color.white.opacity(0.1)) // lighten
                                    .blendMode(.screen)
                            )
                    )
                    .cornerRadius(8)
                    
                    Spacer().frame(height: 32)
                    
                    Text("You can also allow the provider to use cell network data, which works great if you have an unlimited plan.")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 4)
                    
                    HStack {
                        
                        Toggle(isOn: $deviceManager.allowProvidingCell) {
                            Text("Allow providing on cellular network")
                                .font(themeManager.currentTheme.bodyFont)
                        }
                        
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(
                        Rectangle()
                            .fill(themeManager.currentTheme.tintedBackgroundBase)
                            .overlay(
                                Rectangle()
                                    .fill(Color.white.opacity(0.1)) // lighten
                                    .blendMode(.screen)
                            )
                    )
                    .cornerRadius(8)
                    
                    Spacer()
                    
                    NavigationLink(destination: ParticipateReferView(
                        close: close,
                        totalReferrals: totalReferrals,
                        referralCode: referralCode
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
                .padding()
                .frame(minHeight: proxy.size.height)
                
            }
        }
    }
}

#Preview {
    IntroductionParticipateSettingsView(
        close: {},
        totalReferrals: 4,
        referralCode: "ABC123",
        meanReliabilityWeight: 0.2
    )
}
