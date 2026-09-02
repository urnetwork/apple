//
//  IntroductionParticipateSettings.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/25/25.
//

import SwiftUI
import URnetworkSdk

struct IntroductionParticipateSettingsView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
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

                    IntroductionTopBar(step: 3, onSkip: close, onBack: back)

                    Spacer().frame(height: 16)
                    
                    Text("Contribute bandwidth")
                        .font(themeManager.currentTheme.titleFont)

                    Spacer().frame(height: 16)

                    Text("Your choice, completely optional:")
                        .font(themeManager.currentTheme.bodyFontLarge)

                    Spacer().frame(height: 16)

                    IntroBulletPoint(text: "Allow your devices to share internet with each other")

                    IntroBulletPoint(text: "Share your internet with other people ❤️")

                    Spacer().frame(height: 16)
                    
                    VStack(alignment: .leading) {
                        HStack {
                            ProvideModeIndicator()
                            Text("Provide mode")
                                .font(themeManager.currentTheme.bodyFont)
                            Spacer()
                        }
                        ProvideControlModeList()
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
                    
                    #if os(iOS)
                    Spacer().frame(height: 16)
                    
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
                    #endif
                    
                    Spacer(minLength: 24)
                    
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
                    .accessibilityIdentifier("acceptance.introduction.provide.continue")
                    
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

/// The live provide indicator dot (the same encoding as the settings picker).
private struct ProvideModeIndicator: View {

    @EnvironmentObject var deviceManager: DeviceManager

    var body: some View {
        let dot: Color = {
            switch deviceManager.currentProvideMode {
            case SdkProvideModePublic:
                return deviceManager.providePaused ? .urYellow : .urGreen
            case SdkProvideModeNetwork, SdkProvideModeFriendsAndFamily:
                return .urGreen
            default:
                return .urCoral
            }
        }()
        ZStack {
            if deviceManager.currentProvideMode == SdkProvideModePublic {
                Circle()
                    .strokeBorder(deviceManager.providePaused ? Color.urYellow : Color.urGreen, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
            }
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
    }
}

#Preview {
    IntroductionParticipateSettingsView(
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
