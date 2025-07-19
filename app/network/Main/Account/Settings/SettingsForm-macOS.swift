//
//  SettingsForm-macOS.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/18/25.
//

import SwiftUI
import URnetworkSdk

#if os(macOS)
struct SettingsForm_macOS: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    let clientId: SdkId?;
    let clientUrl: String;
    let referralCode: String?;
    let referralNetworkName: String?
    let version: String
    let isUpdatingAccountPreferences: Bool
    let isSeekerOrSagaHolder: Bool
    let copyToPasteboard: (_ value: String) -> Void
    let presentUpdateReferralNetworkSheet: () -> Void
    let presentSigninWithSolanaSheet: () -> Void
    let presentDeleteAccountConfirmation: () -> Void
    
    @Binding var canReceiveNotifications: Bool
    @Binding var canReceiveProductUpdates: Bool
    @Binding var launchAtStartupEnabled: Bool
    
    var body: some View {
        
        GeometryReader { geometry in
                    
                    ScrollView(.vertical) {
                        
                        VStack {
                            
                            HStack {
                                UrLabel(text: "URid")
                                
                                Spacer()
                            }
                            
                            /**
                             * Copy URid
                             */
                            // TODO: copy URid
                            Button(action: {
                                if let clientId = clientId?.idStr {
                                    
                                    copyToPasteboard(clientId)
                                    
                                    snackbarManager.showSnackbar(message: "URid copied to clipboard")
                                }
                            }) {
                                HStack {
                                    Text(clientId?.idStr ?? "")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                    Spacer()
                                    Image(systemName: "document.on.document")
                                }
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(themeManager.currentTheme.tintedBackgroundBase)
                            .cornerRadius(8)
                            
                            Spacer().frame(height: 32)
                            
                            /**
                             * Copy URnetwork link
                             */
                            HStack {
                                UrLabel(text: "Share URnetwork")
                                
                                Spacer()
                            }
                            
                            Button(action: {
                                if let clientId = clientId?.idStr {
                                    
                                    copyToPasteboard("https://ur.io/c?\(clientId)")
                                    
                                    snackbarManager.showSnackbar(message: "URnetwork link copied to clipboard")
                                    
                                }
                            }) {
                                HStack {
                                    Text(clientUrl)
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Image(systemName: "document.on.document")
                                }
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(themeManager.currentTheme.tintedBackgroundBase)
                            .cornerRadius(8)

                            Spacer().frame(height: 32)
                            
                            /**
                             * Copy Referral Link
                             */
                            HStack {
                                UrLabel(text: "Bonus referral code")
                                
                                Spacer()
                            }
                            
                            Button(action: {
                                if let referralCode = referralCode {
                                    
                                    copyToPasteboard(referralCode)
                                    
                                    snackbarManager.showSnackbar(message: "Bonus referral code copied to clipboard")
                                    
                                }
                            }) {
                                HStack {
                                    Text(referralCode ?? "")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Image(systemName: "document.on.document")
                                }
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(themeManager.currentTheme.tintedBackgroundBase)
                            .cornerRadius(8)

                            Spacer().frame(height: 32)
                            
                            /**
                             * Update referral code
                             */
                            HStack {
                                UrLabel(text: "Referral network")
                                
                                Spacer()
                            }
                            
                            Spacer().frame(height: 8)
                            
                            HStack {
                                Text(referralNetworkName ?? "None")
                                    .font(themeManager.currentTheme.bodyFont)
                                Spacer()
                                
                                Button(action: {
                                    presentUpdateReferralNetworkSheet()
                                }) {
                                    Text("Update")
                                }
                                
                            }
                            
                            Spacer().frame(height: 32)
                            
                            HStack {
                                UrLabel(text: "System")
                                
                                Spacer()
                            }
                            
                            UrSwitchToggle(isOn: $launchAtStartupEnabled) {
                                Text("Launch URnetwork on system startup")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                            }
                            
                            Spacer().frame(height: 32)
                            
                            /**
                             * Connections
                             */
                            HStack {
                                UrLabel(text: "Connections")
                                
                                Spacer()
                            }
                            
                            Picker(
                                selection: $deviceManager.provideControlMode
                            ) {
                                ForEach(ProvideControlMode.allCases) { mode in
                                    Text(mode.rawValue.capitalized)
                                        .font(themeManager.currentTheme.bodyFont)
                                        
                                }
                            } label: {
                                Text("Provide mode")
                                    .font(themeManager.currentTheme.bodyFont)
                            }
                            .accentColor(themeManager.currentTheme.textColor)
                            
                            Spacer().frame(height: 16)
                            
                            UrSwitchToggle(isOn: $deviceManager.routeLocal) {
                                Text("Allow local traffic when disconnected")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                            }
                            
                            Spacer().frame(height: 32)
                            
                            /**
                             * Notifications
                             */
                            
                            HStack {
                                UrLabel(text: "Notifications")
                                
                                Spacer()
                            }
                            
                            // TODO: this should be a different UI element
                            // once notifications are enabled, they cannot revoke them through our UI
                            UrSwitchToggle(isOn: $canReceiveNotifications) {
                                Text("Receive connection notifications")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                            }
                            
                            Spacer().frame(height: 32)
                            
                            HStack {
                                UrLabel(text: "Stay in touch")
                                
                                Spacer()
                            }
                            
                            UrSwitchToggle(
                                isOn: $canReceiveProductUpdates,
                                isEnabled: !isUpdatingAccountPreferences
                            ) {
                                Text("Send me product updates")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                            }
                            
                            Spacer().frame(height: 16)
                            
                            HStack {
                                Text("Join the community on [Discord](https://discord.com/invite/RUNZXMwPRK)")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                                Spacer()
                                
                                Button(action: {
                                    if let url = URL(string: "https://discord.com/invite/RUNZXMwPRK") {
                                        
                                        #if canImport(AppKit)
                                        NSWorkspace.shared.open(url)
                                        #endif
                                        
                                    }
                                }) {
                                    Image(systemName: "arrow.forward")
                                        .foregroundColor(themeManager.currentTheme.textColor)
                                }
                            }
                            
                            Spacer().frame(height: 32)
                            
                            HStack {
                                UrLabel(text: "Version and Build info")
                                
                                Spacer()
                            }
                            
                            HStack {
                                Text(version.isEmpty ? "0.0.0" : version)
                                    .font(themeManager.currentTheme.bodyFont)
                                
                                Spacer()
                            }
                            
                            Spacer().frame(height: 64)
                            
                            Button(role: .destructive, action: {
                                presentDeleteAccountConfirmation()
                            }) {
                                Text("Delete account")
                            }
                            
                            Spacer().frame(height: 12)
                            
                        }
                        .padding()
                        .frame(maxWidth: 600)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: geometry.size.height)
                        
                    }
                }
        
    }
}
#endif

//#Preview {
//    SettingsForm_macOS()
//}
