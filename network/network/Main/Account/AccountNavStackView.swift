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
    @StateObject private var viewModel: ViewModel = ViewModel()
    
    @StateObject var accountPreferencesViewModel: AccountPreferencesViewModel
    @StateObject var accountWalletsViewModel: AccountWalletsViewModel
    @StateObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @StateObject var payoutWalletViewModel: PayoutWalletViewModel
    @StateObject private var networkUserViewModel: NetworkUserViewModel
    
    var api: SdkApi
    var device: SdkDeviceRemote
    var logout: () -> Void
    @Binding var provideWhileDisconnected: Bool
    
    init(
        api: SdkApi,
        device: SdkDeviceRemote,
        provideWhileDisconnected: Binding<Bool>,
        logout: @escaping () -> Void
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
        _accountPaymentsViewModel = StateObject.init(wrappedValue: AccountPaymentsViewModel(
                api: api
            )
        )
        
        _payoutWalletViewModel = StateObject.init(wrappedValue: PayoutWalletViewModel(
                api: api
            )
        )
        
        _networkUserViewModel = StateObject(wrappedValue: NetworkUserViewModel(api: api))
        
        self.device = device
        self._provideWhileDisconnected = provideWhileDisconnected
        self.logout = logout
    }
    
    var body: some View {
        NavigationStack(
            path: $viewModel.navigationPath
        ) {
            AccountRootView(
                navigate: viewModel.navigate,
                logout: logout,
                api: api
            )
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationDestination(for: AccountNavigationPath.self) { path in
                switch path {
                    
                case .profile:
                    ProfileView(
                        api: api,
                        back: viewModel.back,
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
                        clientId: device.getClientId(),
                        provideWhileDisconnected: $provideWhileDisconnected,
                        accountPreferencesViewModel: accountPreferencesViewModel
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
                        api: api
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

#Preview {
    AccountNavStackView(
        api: SdkApi(),
        device: SdkDeviceRemote(),
        provideWhileDisconnected: .constant(true),
        logout: {}
    )
    .environmentObject(ThemeManager.shared)
}
