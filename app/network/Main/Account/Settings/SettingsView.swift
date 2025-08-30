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
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let navigate: (AccountNavigationPath) -> Void
    let providerCountries: [SdkConnectLocation]
    
    init(
        api: SdkApi, // todo: deprecrate this in favor of urApiService
        urApiService: UrApiServiceProtocol,
        clientId: SdkId?,
        accountPreferencesViewModel: AccountPreferencesViewModel,
        referralLinkViewModel: ReferralLinkViewModel,
        accountWalletsViewModel: AccountWalletsViewModel,
        navigate: @escaping (AccountNavigationPath) -> Void,
        providerCountries: [SdkConnectLocation]
    ) {
        _viewModel = StateObject(wrappedValue: ViewModel(api: api))
        self.clientId = clientId
        self.accountPreferencesViewModel = accountPreferencesViewModel
        self.referralLinkViewModel = referralLinkViewModel
        self.accountWalletsViewModel = accountWalletsViewModel
        self.api = api
        self.navigate = navigate
        self.providerCountries = providerCountries
        self.urApiService = urApiService
    }
    
    var clientUrl: String {
        guard let clientId = clientId?.idStr else { return "" }
        return "https://ur.io/c?\(clientId)"
    }
    
    var body: some View {

        #if os(iOS)
            SettingsForm_iOS(
                urApiService: urApiService,
                clientId: clientId,
                clientUrl: clientUrl,
                referralCode: referralLinkViewModel.referralCode,
                referralNetworkName: viewModel.referralNetwork?.name,
                version: viewModel.version,
                isUpdatingAccountPreferences: accountPreferencesViewModel.isUpdatingAccountPreferences,
                isSeekerOrSagaHolder: accountWalletsViewModel.isSeekerOrSagaHolder,
                copyToPasteboard: copyToPasteboard,
                presentUpdateReferralNetworkSheet: {
                    viewModel.presentUpdateReferralNetworkSheet = true
                },
                presentSigninWithSolanaSheet: {
                    viewModel.presentSigninWithSolanaSheet = true
                },
                presentDeleteAccountConfirmation: {
                    viewModel.isPresentedDeleteAccountConfirmation = true
                },
                navigate: navigate,
                provideEnabled: deviceManager.provideEnabled,
                providePaused: deviceManager.providePaused,
                canReceiveNotifications: $viewModel.canReceiveNotifications,
                canReceiveProductUpdates: $accountPreferencesViewModel.canReceiveProductUpdates,
            )
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
                .presentationDetents([.height(268)])
                .presentationDragIndicator(.visible)
            }
        
        #elseif os(macOS)
            SettingsForm_macOS(
                urApiService: urApiService,
                clientId: clientId,
                clientUrl: clientUrl,
                referralCode: referralLinkViewModel.referralCode,
                referralNetworkName: viewModel.referralNetwork?.name,
                version: viewModel.version,
                isUpdatingAccountPreferences: accountPreferencesViewModel.isUpdatingAccountPreferences,
                isSeekerOrSagaHolder: accountWalletsViewModel.isSeekerOrSagaHolder,
                copyToPasteboard: copyToPasteboard,
                presentUpdateReferralNetworkSheet: {
                    viewModel.presentUpdateReferralNetworkSheet = true
                },
                presentSigninWithSolanaSheet: {
                    viewModel.presentSigninWithSolanaSheet = true
                },
                presentDeleteAccountConfirmation: {
                    viewModel.isPresentedDeleteAccountConfirmation = true
                },
                navigate: navigate,
                provideEnabled: deviceManager.provideEnabled,
                providePaused: deviceManager.providePaused,
                canReceiveNotifications: $viewModel.canReceiveNotifications,
                canReceiveProductUpdates: $accountPreferencesViewModel.canReceiveProductUpdates,
                launchAtStartupEnabled: $viewModel.launchAtStartupEnabled
            )
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
            }
        
        #endif
        
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
