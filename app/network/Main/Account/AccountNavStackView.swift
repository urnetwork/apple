//
//  AccountView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

struct AccountNavStackView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @StateObject private var viewModel: ViewModel = ViewModel()
    
    @StateObject var accountPreferencesViewModel: AccountPreferencesViewModel
    @StateObject var accountWalletsViewModel: AccountWalletsViewModel
    @StateObject var payoutWalletViewModel: PayoutWalletViewModel
    @StateObject var accountPointsViewModel: AccountPointsViewModel
    
    @ObservedObject var networkUserViewModel: NetworkUserViewModel
    @ObservedObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    var api: SdkApi
    var urApiService: UrApiServiceProtocol
    var device: SdkDeviceRemote
    var logout: () -> Void
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        accountPaymentsViewModel: AccountPaymentsViewModel,
        networkUserViewModel: NetworkUserViewModel,
        referralLinkViewModel: ReferralLinkViewModel
    ) {
        self.api = api
        _accountPreferencesViewModel = StateObject.init(wrappedValue: AccountPreferencesViewModel(
                api: api
            )
        )
        _accountWalletsViewModel = StateObject.init(wrappedValue: AccountWalletsViewModel(
                api: api
            )
        )
        
        _payoutWalletViewModel = StateObject.init(wrappedValue: PayoutWalletViewModel(
                api: api
            )
        )
        
        _accountPointsViewModel = StateObject.init(wrappedValue: AccountPointsViewModel(api: api))
        
        self.accountPaymentsViewModel = accountPaymentsViewModel
        self.networkUserViewModel = networkUserViewModel
        
        self.device = device
        self.logout = logout
        self.referralLinkViewModel = referralLinkViewModel
        self.urApiService = urApiService
    }
    
    var body: some View {
        
        let parsedJwt = deviceManager.parsedJwt
        let networkName = parsedJwt?.networkName ?? ""
        
        NavigationStack(
            path: $viewModel.navigationPath
        ) {
            
            AccountRootView(
                navigate: viewModel.navigate,
                logout: logout,
                api: api,
                referralLinkViewModel: referralLinkViewModel,
                accountPaymentsViewModel: accountPaymentsViewModel,
                networkName: networkName
            )
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationDestination(for: AccountNavigationPath.self) { path in
                switch path {
                    
                case .profile:
                    ProfileView(
                        api: api,
                        back: viewModel.back,
                        networkName: networkName,
                        userAuth: networkUserViewModel.networkUser?.userAuth
                    )
                    .background(themeManager.currentTheme.backgroundColor)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("Profile")
                                .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                        }
                    }
                    
                case .settings:
                    SettingsView(
                        api: api,
                        clientId: device.getClientId(),
                        accountPreferencesViewModel: accountPreferencesViewModel,
                        referralLinkViewModel: referralLinkViewModel,
                        accountWalletsViewModel: accountWalletsViewModel,
                        navigate: viewModel.navigate
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("Settings")
                                .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                        }
                    }
                    
                case .wallets:
                    WalletsView(
                        navigate: viewModel.navigate,
                        api: api,
                        netAccountPoints: accountPointsViewModel.netPoints,
                        payoutPoints: accountPointsViewModel.payoutPoints,
                        multiplierPoints: accountPointsViewModel.multiplierPoints,
                        referralPoints: accountPointsViewModel.referralPoints,
                        fetchAccountPoints: accountPointsViewModel.fetchAccountPoints,
                        referralLinkViewModel: referralLinkViewModel,
                    )
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("Payout Wallets")
                                .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                        }
                    }
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    .environmentObject(accountPaymentsViewModel)
                    .environmentObject(accountWalletsViewModel)
                    .environmentObject(payoutWalletViewModel)
                    
                case .wallet(let wallet):
                    
                    let payments = accountPaymentsViewModel.filterPaymentsByWalletId(wallet.walletId)
                    
                    WalletView(
                        wallet: wallet,
                        navigate: viewModel.navigate,
                        payoutWalletId: payoutWalletViewModel.payoutWalletId,
                        payments: payments,
                        promptRemoveWallet: accountWalletsViewModel.promptRemoveWallet,
                        fetchPayments: accountPaymentsViewModel.fetchPayments
                    )
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("\(wallet.blockchain) Wallet")
                                .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                        }
                    }
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    .environmentObject(accountPaymentsViewModel)
                    .environmentObject(payoutWalletViewModel)
                    
                    
                case .payout(let payment, let accountPoint):
                    
                    let toolbarTitle = if let completeTime = payment.completeTime {
                        "+\(String(format: "%.2f", payment.tokenAmount)) \(payment.tokenType) (\(completeTime.format("Jan 2, 2006")))"
                    } else {
                        "Pending payout"
                    }
                    
                    PayoutItemView(
                        navigate: viewModel.navigate,
                        payment: payment,
                        accountPointsViewModel: accountPointsViewModel,
                        isMultiplierTokenHolder: accountWalletsViewModel.isSeekerOrSagaHolder
                    )
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(toolbarTitle)
                                .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                        }
                    }
                    
                case .blockedLocations:

                    BlockedLocationsView(api: urApiService)
                    
                }
                
            }
        }
        .confirmationDialog(
            "Are you sure you want to remove this wallet?",
            isPresented: $accountWalletsViewModel.isPresentingRemoveWalletSheet
        ) {
            Button("Remove wallet", role: .destructive) {
                removeWallet()
            }
        }
    }
    
    private func removeWallet() {
        
        viewModel.back()
        
        Task {
            let result = await accountWalletsViewModel.removeWallet()
            
            if case .failure(let error) = result {
                
                // TODO: snackbar error
                
            }
        }
    }
    
}

//#Preview {
//    AccountNavStackView(
//        api: SdkApi(),
//        device: SdkDeviceRemote(),
//        provideWhileDisconnected: .constant(true),
//        logout: {},
//        accountPaymentsViewModel: AccountPaymentsViewModel(api: nil),
//        networkUserViewModel: NetworkUserViewModel(api: SdkApi())
//    )
//    .environmentObject(ThemeManager.shared)
//}
