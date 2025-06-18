//
//  SettingsView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk
#if os(macOS)
import ServiceManagement
#endif

struct SettingsView: View {
    
    @StateObject private var viewModel: ViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    
    var clientId: SdkId?
    @ObservedObject var accountPreferencesViewModel: AccountPreferencesViewModel
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    @ObservedObject var accountWalletsViewModel: AccountWalletsViewModel
    
    var api: SdkApi
    
    init(
        api: SdkApi,
        clientId: SdkId?,
        accountPreferencesViewModel: AccountPreferencesViewModel,
        referralLinkViewModel: ReferralLinkViewModel,
        accountWalletsViewModel: AccountWalletsViewModel
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(api: api))
        self.clientId = clientId
        self.accountPreferencesViewModel = accountPreferencesViewModel
        self.referralLinkViewModel = referralLinkViewModel
        self.accountWalletsViewModel = accountWalletsViewModel
        self.api = api
    }
    
    var clientUrl: String {
        guard let clientId = clientId?.idStr else { return "" }
        return "https://ur.io/c?\(clientId)"
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            
            ScrollView(.vertical) {
                
                VStack {
                    
//                    HStack {
//                        Text("Settings")
//                            .font(themeManager.currentTheme.titleFont)
//                            .foregroundColor(themeManager.currentTheme.textColor)
//                        
//                        Spacer()
//                    }
//                    
//                    Spacer().frame(height: 64)
  
                    // TODO: add this back in for subscription
//                    HStack {
//                        UrLabel(text: "Plan")
//                        
//                        Spacer()
//                    }
//                    
//                    HStack {
//                        
//                        Text("URnetwork Member")
//                            .font(themeManager.currentTheme.bodyFont)
//                            .foregroundColor(themeManager.currentTheme.textColor)
//                        
//                        
//                        Spacer()
//                        Button(action: {}) {
//                            Text("Change")
//                        }
//                        
//                    }
//                    
//                    Spacer().frame(height: 32)
                    
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
                        if let referralCode = referralLinkViewModel.referralCode {
                            
                            copyToPasteboard(referralCode)
                            
                            snackbarManager.showSnackbar(message: "Bonus referral code copied to clipboard")
                            
                        }
                    }) {
                        HStack {
                            Text(referralLinkViewModel.referralCode ?? "")
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
                        Text(viewModel.referralNetwork?.name ?? "None")
                            .font(themeManager.currentTheme.bodyFont)
                        Spacer()
                        
                        Button(action: {
                            viewModel.presentUpdateReferralNetworkSheet = true
                        }) {
                            Text("Update")
                        }
                        
                    }
                    
                    Spacer().frame(height: 32)
                    
                    
                    #if os(macOS)
                    
                    HStack {
                        UrLabel(text: "System")
                        
                        Spacer()
                    }
                    
                    UrSwitchToggle(isOn: $viewModel.launchAtStartupEnabled) {
                        Text("Launch URnetwork on system startup")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                    
                    Spacer().frame(height: 32)
                    
                    #endif
                    
                    
                    /**
                     * Connections
                     */
                    HStack {
                        UrLabel(text: "Connections")
                        
                        Spacer()
                    }
                    
                    UrSwitchToggle(isOn: $deviceManager.provideWhileDisconnected) {
                        Text("Provide while disconnected")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                    
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
                    UrSwitchToggle(isOn: $viewModel.canReceiveNotifications) {
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
                        isOn: $accountPreferencesViewModel.canReceiveProductUpdates,
                        isEnabled: !accountPreferencesViewModel.isUpdatingAccountPreferences
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
                                
                                #if canImport(UIKit)
                                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                #elseif canImport(AppKit)
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
                        Text(viewModel.version.isEmpty ? "0.0.0" : viewModel.version)
                            .font(themeManager.currentTheme.bodyFont)
                        
                        Spacer()
                    }
                    
                    #if os(iOS)
                    
                    Spacer().frame(height: 32)
                    
                    HStack {
                        UrLabel(text: "Earning multipliers")
                        
                        Spacer()
                    }
                    
                    Spacer().frame(height: 8)
                    
                    HStack {
                        Text("Claim multiplier")
                            .font(themeManager.currentTheme.bodyFont)
                        Spacer()
                        
                        if (accountWalletsViewModel.isSeekerOrSagaHolder) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.urGreen)
                                .frame(width: 16)
                        } else {
                            Button(action: {
                                viewModel.presentSigninWithSolanaSheet = true
                            }) {
                                Text("Verify")
                            }
                        }
                        
                    }
                    
                    Spacer().frame(height: 4)
                    
                    HStack {
                        Text("Connect a wallet with the Seeker Pre-Order Token")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        
                        Spacer()
                    }
                    
                    #endif
                    
                    Spacer().frame(height: 64)
                    
                    Button(role: .destructive, action: {
                        viewModel.isPresentedDeleteAccountConfirmation = true
                    }) {
                        Text("Delete account")
                    }
                    
                    Spacer().frame(height: 12)
                    
                }
                .padding()
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: geometry.size.height)
                // .frame(maxWidth: .infinity)
                
                
            }
        }
        .confirmationDialog(
            "Are you sure you want to delete your account?",
            isPresented: $viewModel.isPresentedDeleteAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete account", role: .destructive) {
                
                Task {
                    let result = await viewModel.deleteAccount()
                    self.handleResult(result)
                }
                
            }
        }
        .sheet(isPresented: $viewModel.presentSigninWithSolanaSheet) {
            
            SolanaSignMessageSheet(
                isSigningMessage: viewModel.isSigningMessage,
                setIsSigningMessage: viewModel.setIsSigningMessage,
                signButtonText: "Confirm Seeker Token",
                signButtonLabelText: "Claim multiplier",
                message: connectWalletProviderViewModel.claimSeekerTokenMessage,
                dismiss: {
                    viewModel.presentSigninWithSolanaSheet = false
                }
            )
            .presentationDetents([.height(148)])
        }
        .onOpenURL { url in
            connectWalletProviderViewModel
                .handleDeepLink(
                    url,
                    onSignature: { signature in
                        
                        guard let pk = connectWalletProviderViewModel.connectedPublicKey else {
                            snackbarManager.showSnackbar(message: "Couldn't parse public key, please try again later.")
                            return
                        }
                        
                        Task {
                            await handleSolanaWalletSignature(
                                message: connectWalletProviderViewModel.claimSeekerTokenMessage,
                                signature: signature,
                                publicKey: pk
                            )
                        }
                        
                    }
                )
        }
        .sheet(isPresented: $viewModel.presentUpdateReferralNetworkSheet) {
            UpdateReferralNetworkSheet(
                api: api,
                onSuccess: {
                    Task {
                        await viewModel.fetchReferralNetwork()
                    }
                    viewModel.presentUpdateReferralNetworkSheet = false
                },
                dismiss: {
                    viewModel.presentUpdateReferralNetworkSheet = false
                },
                referralNetwork: viewModel.referralNetwork
            )
            #if os(iOS)
            .presentationDetents([.height(268)])
            .presentationDragIndicator(.visible)
            #endif
        }
    }
    
    private func handleSolanaWalletSignature(message: String, signature: String, publicKey: String) async {
        
        let result = await accountWalletsViewModel.verifySeekerOrSagaOwnership(
            publicKey: publicKey,
            message: message,
            signature: signature
        )
        
        switch result {
        case .success:
            snackbarManager.showSnackbar(message: "Successfully claimed multiplier!")
            viewModel.presentSigninWithSolanaSheet = false
        case .failure(let error):
            snackbarManager.showSnackbar(message: "Sorry, there was an error claiming multiplier: \(error)")
        }
        
    }
    
    private func handleResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            deviceManager.logout()
            break
        case .failure(let error):
            print("Error deleting account: \(error)")
            snackbarManager.showSnackbar(message: "Sorry, there was an error deleting your account.")
        }
    }
    
    private func copyToPasteboard(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        #endif
    }
}

//#Preview {
//    
//    let themeManager = ThemeManager.shared
//    let accountPreferenceViewModel = AccountPreferencesViewModel(api: SdkApi())
//    
//    SettingsView(
//        api: SdkApi(),
//        clientId: nil,
//        accountPreferencesViewModel: accountPreferenceViewModel
//    )
//    .environmentObject(themeManager)
//    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
//}
