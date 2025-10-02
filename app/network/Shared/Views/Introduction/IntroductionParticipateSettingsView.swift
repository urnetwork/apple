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
        
        ScrollView {
         
            VStack(alignment: .leading) {
                
                Text("Step 1")
                    .font(themeManager.currentTheme.titleFont)
                
                VStack(alignment: .leading) {
                    
                    Text("A local provider will run when you are connected to the network. There are over 30k providers today, and we have zero known security or ISP incidents. We value the ability for people to participate without issues, and have built the protocol to put safety first. [Learn more at the protocol page](https://ur.io/protocol).")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer().frame(height: 16)
                    
                    Divider()
                    
                    Spacer().frame(height: 16)
                    
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
                    
                    Spacer().frame(height: 16)
                    
                    Divider()
                    
                    Spacer().frame(height: 16)
                    
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
                    
                    Spacer().frame(height: 16)
                    
                    Divider()
                    
                    Spacer().frame(height: 16)
                    
                    NavigationLink(destination: ParticipateReferView(
                        close: close,
                        totalReferrals: totalReferrals,
                        referralCode: referralCode
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
    IntroductionParticipateSettingsView(
        close: {},
        totalReferrals: 4,
        referralCode: "ABC123",
        meanReliabilityWeight: 0.2
    )
}
