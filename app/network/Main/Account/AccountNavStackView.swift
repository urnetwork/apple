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
    @StateObject var accountPointsStore: AccountPointsStore
    
    @ObservedObject var networkUserViewModel: NetworkUserViewModel
    @ObservedObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let device: SdkDeviceRemote
    let logout: () -> Void
    let providerCountries: [SdkConnectLocation]
    let networkReliabilityWindow: SdkReliabilityWindow?
    let fetchNetworkReliability: () async -> Void
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        accountPaymentsViewModel: AccountPaymentsViewModel,
        networkUserViewModel: NetworkUserViewModel,
        referralLinkViewModel: ReferralLinkViewModel,
        providerCountries: [SdkConnectLocation],
        networkReliabilityWindow: SdkReliabilityWindow?,
        fetchNetworkReliability: @escaping () async -> Void
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
        
        _accountPointsStore = StateObject.init(wrappedValue: AccountPointsStore(api: api))
        
        self.accountPaymentsViewModel = accountPaymentsViewModel
        self.networkUserViewModel = networkUserViewModel
        
        self.device = device
        self.logout = logout
        self.referralLinkViewModel = referralLinkViewModel
        self.urApiService = urApiService
        self.providerCountries = providerCountries
        self.networkReliabilityWindow = networkReliabilityWindow
        self.fetchNetworkReliability = fetchNetworkReliability
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
                networkName: networkName,
                meanReliabilityWeight: networkReliabilityWindow?.meanReliabilityWeight ?? 0
            )
            .navigationTitle("Account")
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
                    .navigationTitle("Profile")
                    
                case .settings:
                    SettingsView(
                        api: urApiService,
                        clientId: device.getClientId(),
                        accountPreferencesViewModel: accountPreferencesViewModel,
                        referralLinkViewModel: referralLinkViewModel,
                        accountWalletsViewModel: accountWalletsViewModel,
                        navigate: viewModel.navigate,
                        providerCountries: providerCountries,
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    .navigationTitle("Settings")
                    
                case .wallets:
                    WalletsView(
                        navigate: viewModel.navigate,
                        api: urApiService,
                        netAccountPoints: accountPointsStore.netPoints,
                        payoutPoints: accountPointsStore.payoutPoints,
                        multiplierPoints: accountPointsStore.multiplierPoints,
                        referralPoints: accountPointsStore.referralPoints,
                        reliabilityPoints: accountPointsStore.reliabilityPoints,
                        fetchAccountPoints: accountPointsStore.fetchAccountPoints,
                        networkReliabilityWindow: networkReliabilityWindow,
                        fetchNetworkReliability: fetchNetworkReliability,
                        referralLinkViewModel: referralLinkViewModel,
                    )
                    .navigationTitle("Payout Wallets")
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
                    .navigationTitle("\(wallet.blockchain) Wallet")
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    .environmentObject(accountPaymentsViewModel)
                    .environmentObject(payoutWalletViewModel)
                    
                    
                case .payout(let payment, _):
                    
                    let toolbarTitle = if let completeTime = payment.completeTime {
                        "+\(String(format: "%.2f", payment.tokenAmount)) \(payment.tokenType) (\(completeTime.format("Jan 2, 2006")))"
                    } else {
                        "Pending payout"
                    }
                    
                    PayoutItemView(
                        navigate: viewModel.navigate,
                        payment: payment,
                        accountPointsViewModel: accountPointsStore,
                        isMultiplierTokenHolder: accountWalletsViewModel.isSeekerOrSagaHolder
                    )
                    .navigationTitle(toolbarTitle)
                    
                case .blockedLocations:

                    BlockedLocationsView(
                        api: urApiService,
                        countries: providerCountries
                    )
                    .navigationTitle("Blocked Locations")
                    
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
