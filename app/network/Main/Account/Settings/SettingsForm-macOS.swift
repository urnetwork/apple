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
    let referralCode: String?;
    let totalReferrals: Int
    let referralNetworkName: String?
    let version: String
    let isUpdatingAccountPreferences: Bool
    let copyToPasteboard: (_ value: String) -> Void
    let presentUpdateReferralNetworkSheet: () -> Void
    let presentDeleteAccountConfirmation: () -> Void
    let navigate: (AccountNavigationPath) -> Void
    let provideEnabled: Bool
    let providePaused: Bool
    let deviceName: String
    let deviceSpec: String
    let presentRenameDevice: () -> Void

    @Binding var canReceiveNotifications: Bool
    @Binding var canReceiveProductUpdates: Bool
    @Binding var launchAtStartupEnabled: Bool
    
    let networkUserViewModel: NetworkUserViewModel?
    let viewModel: SettingsView.ViewModel
    
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

                    /**
                     * referral royalty: networks with at least one referral get
                     * the crowned frog mascot (same as the ur.io site)
                     */
                    if 0 < totalReferrals {
                        VStack {
                            Image("ReferralFrog")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 80)
                            Text("You're referral royalty!")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                    }

                    HStack {
                        UrLabel(text: "Client ID")

                        Spacer()
                    }
                    
                    /**
                     * Copy client id
                     */
                    Button(action: {
                        if let clientId = clientId?.idStr {

                            copyToPasteboard(clientId)

                            snackbarManager.showSnackbar(message: String(localized: "Client ID copied to clipboard"))
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
                     * Copy Referral Link
                     */
                    HStack {
                        UrLabel(text: "Bonus referral code")
                        
                        Spacer()
                    }
                    
                    Button(action: {
                        if let referralCode = referralCode {
                            
                            copyToPasteboard(referralCode)
                            
                            snackbarManager.showSnackbar(message: String(localized: "Bonus referral code copied to clipboard"))
                            
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
                    
                    // MARK: - Seedphrase Management
                    
                    HStack {
                        UrLabel(text: "Seedphrase")
                        
                        Spacer()
                    }
                    
                    VStack(alignment: .leading) {
                        if let networkUser = networkUserViewModel?.networkUser {
                            let hasSeedphrase = authTypesContains(networkUser.authTypes, "seedphrase")
                            if hasSeedphrase {
                            HStack {
                                Button(action: {
                                    viewModel.confirmRegenerateSeedphrase()
                                }) {
                                    Text("Regenerate Seedphrase")
                                }
                                if viewModel.isRegeneratingSeedphrase {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Spacer()
                            }
                            .disabled(viewModel.isRegeneratingSeedphrase)
                        } else {
                            HStack {
                                Button(action: {
                                    viewModel.confirmGenerateSeedphrase()
                                }) {
                                    Text("Generate Seedphrase")
                                }
                                if viewModel.isGeneratingSeedphrase {
                                    ProgressView().scaleEffect(0.7)
                                }
                                Spacer()
                            }
                            .disabled(viewModel.isGeneratingSeedphrase)
                        }
                    } else {
                        Text("Loading...")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    
                    Text("A seedphrase lets you recover your account if you lose access.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)
                    
                    // MARK: - Sign-In Methods
                    
                    HStack {
                        UrLabel(text: "Sign-In Methods")
                        
                        Spacer()
                    }
                    
                    VStack(alignment: .leading) {
                        if let networkUser = networkUserViewModel?.networkUser {
                            let authMethods = parseAuthMethods(networkUser)

                            ForEach(authMethods, id: \.self) { method in
                                HStack {
                                    Text(methodDisplayName(method))
                                        .font(themeManager.currentTheme.bodyFont)
                                    Spacer()
                                    Button(role: .destructive) {
                                        viewModel.presentRemoveAuth(method)
                                    } label: {
                                        Text("Remove")
                                    }
                                }
                                Spacer().frame(height: 8)
                            }

                            Spacer().frame(height: 4)

                            Button(action: {
                                viewModel.presentAddAuthSheet = true
                            }) {
                                Text("Add sign-in method")
                            }
                        } else {
                            HStack {
                                Text("Loading sign-in methods...")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                                Spacer()
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)
                    
                    /**
                     * System
                     */
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
                        }
                        
                        
                    }
                    .padding()
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    Spacer().frame(height: 32)

                    /**
                     * Device
                     */
                    HStack {
                        UrLabel(text: "Device")

                        Spacer()
                    }

                    VStack {

                        HStack {
                            Text("Name")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            Spacer()
                            Text(deviceName.isEmpty ? "—" : deviceName)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .lineLimit(1)
                            Image(systemName: "pencil")
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            presentRenameDevice()
                        }

                        Spacer().frame(height: 16)
                        Divider()
                        Spacer().frame(height: 16)

                        HStack {
                            Text("Spec")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            Spacer()
                            Text(deviceSpec.isEmpty ? "—" : deviceSpec)
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .lineLimit(1)
                                .truncationMode(.middle)
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

                    Spacer().frame(height: 16)

                    HStack {
                        Link(destination: URL(string: "https://ur.xyz")!) {
                            Text("Uses the UR Protocol")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }

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
