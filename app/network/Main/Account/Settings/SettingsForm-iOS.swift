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
    
    let networkUserViewModel: NetworkUserViewModel?
    let viewModel: SettingsView.ViewModel
    
    var body: some View {

        Form {

            /**
             * referral royalty: networks with at least one referral get the
             * crowned frog mascot (same as the ur.io site)
             */
            if 0 < totalReferrals {
                Section {
                    HStack {
                        Spacer()
                        VStack {
                            Image("ReferralFrog")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 80)
                            Text("You're referral royalty!")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section("Client ID") {

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
            
            // MARK: - Seedphrase Management

            Section("Seedphrase") {
                VStack(alignment: .leading, spacing: 8) {
                    if let networkUser = networkUserViewModel?.networkUser {
                        let hasSeedphrase = authTypesContains(networkUser.authTypes, "seedphrase")
                        if hasSeedphrase {
                            Button(action: {
                                viewModel.confirmRegenerateSeedphrase()
                            }) {
                                HStack {
                                    Text("Regenerate Seedphrase")
                                        .font(themeManager.currentTheme.bodyFont)
                                    Spacer()
                                    if viewModel.isRegeneratingSeedphrase {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(viewModel.isRegeneratingSeedphrase)
                        } else {
                            Button(action: {
                                viewModel.confirmGenerateSeedphrase()
                            }) {
                                HStack {
                                    Text("Generate Seedphrase")
                                        .font(themeManager.currentTheme.bodyFont)
                                    Spacer()
                                    if viewModel.isGeneratingSeedphrase {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(viewModel.isGeneratingSeedphrase)
                        }
                    } else {
                        Button(action: {
                            viewModel.confirmGenerateSeedphrase()
                        }) {
                            HStack {
                                Text("Generate Seedphrase")
                                    .font(themeManager.currentTheme.bodyFont)
                                Spacer()
                                if viewModel.isGeneratingSeedphrase {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(viewModel.isGeneratingSeedphrase)
                    }
                    
                    Text("A seedphrase lets you recover your account if you lose access.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }

            // MARK: - Sign-In Methods

            Section("Sign-In Methods") {
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
                    }

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
                        ProgressView()
                    }
                }
            }
            
            Section("Account") {
                /**
                 * Update referral code
                 */
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
                }
                
                HStack {
                    Text("Balance Codes")
                        .font(themeManager.currentTheme.bodyFont)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    navigate(.transferBalanceCodes)
                }
                
            }
            
            Section("Device") {

                /**
                 * Device name, editable
                 */
                Button(action: {
                    presentRenameDevice()
                }) {
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
                }
                .buttonStyle(.plain)

                /**
                 * Device spec, read only
                 */
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

            Section("Connections") {

                /**
                 * Connections
                 */
                
                HStack {
                    ProvideControlPicker()
                }
                
                UrSwitchToggle(isOn: $deviceManager.allowProvidingCell) {
                    Text("Allow providing on cellular network")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                
                
                UrSwitchToggle(isOn: Binding(
                    get: { !deviceManager.routeLocal },
                    set: { deviceManager.routeLocal = !$0 }
                )) {
                    Text("Kill switch")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                
                HStack {
                    Text("Blocked locations")
                        .font(themeManager.currentTheme.bodyFont)
                    Spacer()
                    Image(systemName: "chevron.right")
                        // .renderingMode(.)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    navigate(.blockedLocations)
                    // navigate to blocked
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
                
                /**
                 * Discord Link
                 */
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
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                }
                
                /**
                 * DePIN Hub Link
                 */
                
                DePinHubSettingsLinkRow()
                
            }
            
            Section("General") {
                HStack {

                    Text("Version and Build info")
                        .font(themeManager.currentTheme.bodyFont)

                    Spacer()

                    Text(version.isEmpty ? "0.0.0" : version)
                        .font(themeManager.currentTheme.bodyFont)
                }

                Link(destination: URL(string: "https://ur.xyz")!) {
                    Text("Uses the UR Protocol")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
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
        .scrollContentBackground(.hidden)
        .background(themeManager.currentTheme.backgroundColor)
    }
    
}
#endif

//#Preview {
//    SettingsForm_iOS()
//}
