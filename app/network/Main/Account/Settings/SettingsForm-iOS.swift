//
//  SettingsForm-iOS.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/18/25.
//

import SwiftUI
import URnetworkSdk

#if os(iOS)
struct SettingsForm_iOS: View {
    
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
    
    var body: some View {
        Form {
            
            Section("URid") {
             
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
                }
                .buttonStyle(.plain)
                
            }
            
            Section("Share URnetwork") {
             
                /**
                 * Copy URnetwork link
                 */
                
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
                }
                .buttonStyle(.plain)
                
            }
         
            Section("Bonus referral code") {
            
                /**
                 * Copy Referral Link
                 */
                
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
                }
                .buttonStyle(.plain)
                
            }
            
            Section("Referral network") {
                /**
                 * Update referral code
                 */
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
            }
            
            
            Section("Connections") {
            
                /**
                 * Connections
                 */
                
                HStack {
                    
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
                    
                }
                
                UrSwitchToggle(isOn: $deviceManager.routeLocal) {
                    Text("Allow local traffic when disconnected")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                
            }
            
            Section("Stay in touch") {
                /**
                 * Notifications
                 */
                
                
                // TODO: this should be a different UI element
                // once notifications are enabled, they cannot revoke them through our UI
                UrSwitchToggle(isOn: $canReceiveNotifications) {
                    Text("Receive connection notifications")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                }
                
                UrSwitchToggle(
                    isOn: $canReceiveProductUpdates,
                    isEnabled: !isUpdatingAccountPreferences
                ) {
                    Text("Send me product updates")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                }
                
                HStack {
                    Text("Join the community on [Discord](https://discord.com/invite/RUNZXMwPRK)")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer()
                    
                    Button(action: {
                        if let url = URL(string: "https://discord.com/invite/RUNZXMwPRK") {
                            
                            #if canImport(UIKit)
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                            #endif
                            
                        }
                    }) {
                        Image(systemName: "arrow.forward")
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                }
            }
            
            Section("General") {
                HStack {
                    
                    Text("Version and Build info")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer()
                    
                    Text(version.isEmpty ? "0.0.0" : version)
                        .font(themeManager.currentTheme.bodyFont)
                }
            }
            
            Section("Earning multipliers") {
                
                VStack {
                 
                    HStack {
                        Text("Claim multiplier")
                            .font(themeManager.currentTheme.bodyFont)
                        Spacer()
                        
                        if (isSeekerOrSagaHolder) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.urGreen)
                                .frame(width: 16)
                        } else {
                            Button(action: {
                                presentSigninWithSolanaSheet()
                            }) {
                                Text("Verify")
                            }
                        }
                        
                    }
                    
                    HStack {
                        Text("Connect a wallet with the Seeker Pre-Order Token")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        
                        Spacer()
                    }
                    
                }
                
            }
            
            Section("Danger") {
                Button(role: .destructive, action: {
                    presentDeleteAccountConfirmation()
                }) {
                    Text("Delete account")
                }
            }
            
            
        }
    }
}
#endif

//#Preview {
//    SettingsForm_iOS()
//}
