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
    
    let urApiService: UrApiServiceProtocol
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
    let navigate: (AccountNavigationPath) -> Void
    let provideEnabled: Bool
    let providePaused: Bool
    
    @Binding var canReceiveNotifications: Bool
    @Binding var canReceiveProductUpdates: Bool
    @Binding var launchAtStartupEnabled: Bool
    
    var provideIndicatorColor: Color {
        if !provideEnabled {
            return .urCoral
        } else if providePaused {
            return .urYellow
        } else {
            return .urGreen
        }
    }
    
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
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
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
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

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
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)
                    
                    HStack {
                        UrLabel(text: "System")
                        
                        Spacer()
                    }
                    
                    HStack {
                        
                        Toggle(isOn: $launchAtStartupEnabled) {
                            Text("Launch URnetwork on system startup")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)
                    
                    
                    HStack {
                        UrLabel(text: "Account")
                        
                        Spacer()
                    }
                    
                    VStack {
                        
                        HStack {
                            Text("Auth code")
                                .font(themeManager.currentTheme.bodyFont)
                            
                            Spacer()
                            
                            AuthCodeCreate(
                                api: urApiService,
                                copyToPasteboard: copyToPasteboard
                            )
                            
                        }
                        
                        HStack {
                            Text("Created auth codes expire after 5 minutes")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                            
                            Spacer()
                        }
                        
                        Spacer().frame(height: 16)
                        Divider()
                        Spacer().frame(height: 16)
                        
                        HStack {
                            Text("Balance Codes")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigate(.transferBalanceCodes)
                            // navigate to blocked
                        }
                        
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)
                    
                    /**
                     * Connections
                     */
                    HStack {
                        UrLabel(text: "Connections")
                        
                        Spacer()
                    }
                    
                    VStack {
                        
                        HStack {
                            Picker(
                                selection: $deviceManager.provideControlMode
                            ) {
                                ForEach(ProvideControlMode.allCases) { mode in
                                    Text(mode.rawValue.capitalized)
                                        .font(themeManager.currentTheme.bodyFont)
                                        
                                }
                            } label: {
                                
                                HStack {
                                    Circle()
                                        .frame(width: 8, height: 8)
                                        .foregroundColor(provideIndicatorColor)
                                    
                                    
                                    Text("Provide mode")
                                        .font(themeManager.currentTheme.bodyFont)
                                }
                                
                            }
                            .accentColor(themeManager.currentTheme.textColor)
                            
                            Spacer()
                        }
                        
                        Spacer().frame(height: 16)
                        Divider()
                        Spacer().frame(height: 16)
                        
                        HStack {
                         
                            Toggle(isOn: Binding(
                                get: { !deviceManager.routeLocal },
                                set: { deviceManager.routeLocal = !$0 }
                            )) {
                                Text("Kill switch")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                            }
                            
                            Spacer()
                            
                        }
                        
                        Spacer().frame(height: 16)
                        Divider()
                        Spacer().frame(height: 16)
                        
                        HStack {
                            Text("Blocked locations")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            navigate(.blockedLocations)
                            // navigate to blocked
                        }
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)
                    
                    /**
                     * Notifications
                     */
                    
                    HStack {
                        UrLabel(text: "Notifications")
                        
                        Spacer()
                    }
                    
                    HStack {
                        // TODO: this should be a different UI element
                        // once notifications are enabled, they cannot revoke them through our UI
                        Toggle(isOn: $canReceiveNotifications) {
                            Text("Receive connection notifications")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                        }
                        .disabled(canReceiveNotifications)
                        
                        Spacer()
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    
                    Spacer().frame(height: 32)
                    
                    HStack {
                        UrLabel(text: "Stay in touch")
                        
                        Spacer()
                    }
                    
                    VStack(alignment: .leading) {
                     
                        Toggle(
                            isOn: $canReceiveProductUpdates,
                        ) {
                            Text("Send me product updates")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                        }
                        .disabled(isUpdatingAccountPreferences)
                        
                        Spacer().frame(height: 16)
                        Divider()
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
                        
                        Spacer().frame(height: 16)
                        Divider()
                        Spacer().frame(height: 16)
                        
                        /**
                         * DePIN Hub Link
                         */
                        DePinHubSettingsLinkRow()
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    
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
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
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
