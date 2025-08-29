//
//  WalletsRootView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/15.
//

import SwiftUI
import URnetworkSdk

struct WalletsView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @EnvironmentObject var accountWalletsViewModel: AccountWalletsViewModel
    @EnvironmentObject var payoutWalletViewModel: PayoutWalletViewModel
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    
    var navigate: (AccountNavigationPath) -> Void
    var api: UrApiServiceProtocol
    var netAccountPoints: Double
    var payoutPoints: Double
    var multiplierPoints: Double
    var referralPoints: Double
    var reliabilityPoints: Double
    var fetchAccountPoints: () async -> Void
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    @StateObject private var viewModel: ViewModel
    @StateObject private var networkReliabilityStore: NetworkReliabilityStore
    
    init(
        navigate: @escaping (AccountNavigationPath) -> Void,
        api: UrApiServiceProtocol,
        netAccountPoints: Double,
        payoutPoints: Double,
        multiplierPoints: Double,
        referralPoints: Double,
        reliabilityPoints: Double,
        fetchAccountPoints: @escaping () async -> Void,
        referralLinkViewModel: ReferralLinkViewModel,
    ) {

        self.navigate = navigate
        self.api = api
        self.netAccountPoints = netAccountPoints
        self.payoutPoints = payoutPoints
        self.multiplierPoints = multiplierPoints
        self.referralPoints = referralPoints
        self.reliabilityPoints = reliabilityPoints
        self.fetchAccountPoints = fetchAccountPoints
        self.referralLinkViewModel = referralLinkViewModel
        _viewModel = StateObject(wrappedValue: ViewModel())
        _networkReliabilityStore = StateObject(wrappedValue: NetworkReliabilityStore(api: api))
    }
    
    var body: some View {
        
        Group {
         
            if (accountWalletsViewModel.wallets.isEmpty) {
                /**
                 * Empty wallet view
                 */
                GeometryReader { geometry in
                    
                    ScrollView {
                        VStack {
                            
                            WalletsHeader(
                                unpaidMegaBytes: accountWalletsViewModel.unpaidDataFormatted,
                                netAccountPoints: netAccountPoints,
                                payoutPoints: payoutPoints,
                                multiplierPoints: multiplierPoints,
                                referralPoints: referralPoints,
                                referralLinkViewModel: referralLinkViewModel,
                            )
                            
                            EmptyWalletsView(
                                presentConnectWalletSheet: $viewModel.presentConnectWalletSheet
                            )
                            
                        }
                        .frame(minHeight: geometry.size.height)
                    }
                }
                
            } else {
                
                /**
                 * Populated wallets view
                 */
                
                ScrollView {
                 
                    VStack {
                        
                        WalletsHeader(
                            unpaidMegaBytes: accountWalletsViewModel.unpaidDataFormatted,
                            netAccountPoints: netAccountPoints,
                            payoutPoints: payoutPoints,
                            multiplierPoints: multiplierPoints,
                            referralPoints: referralPoints,
                            referralLinkViewModel: referralLinkViewModel
                        )
                        
                        PopulatedWalletsView(
                            navigate: navigate,
                            isSeekerOrSagaHolder: accountWalletsViewModel.isSeekerOrSagaHolder,
                            netPoints: netAccountPoints,
                            payoutPoints: payoutPoints,
                            referralPoints: referralPoints,
                            multiplierPoints: multiplierPoints,
                            reliabilityPoints: reliabilityPoints,
                            networkReliabilityWindow: networkReliabilityStore.reliabilityWindow,
                            presentConnectWalletSheet: $viewModel.presentConnectWalletSheet
                        )
                    }
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                    
                }
                
            }
            
        }
        .refreshable {
            async let fetchWallets: Void = accountWalletsViewModel.fetchAccountWallets()
            async let fetchPayments: Void = accountPaymentsViewModel.fetchPayments()
            async let fetchTransferStats: Void = accountWalletsViewModel.fetchTransferStats()
            async let fetchAccountPoints: Void = fetchAccountPoints()
            async let fetchReferralLink: Void = referralLinkViewModel.fetchReferralLink()
            async let fetchNetworkReliability: Void = networkReliabilityStore.getNetworkReliability()
            
            // Wait for all tasks to complete
            (_, _, _, _, _, _) = await (
                fetchWallets,
                fetchPayments,
                fetchTransferStats,
                fetchAccountPoints,
                fetchReferralLink,
                fetchNetworkReliability
            )

        }
        .onReceive(connectWalletProviderViewModel.$connectedPublicKey) { walletAddress in
            
            /**
             * Once we receive an address from the wallet, here we associate the address with the network
             */
            
            if let walletAddress = walletAddress {
                
                // TODO: check if wallet address already present in existing wallets
                
                Task {
                    // TODO: error handling on connect wallet
                    let _ = await accountWalletsViewModel.connectWallet(walletAddress: walletAddress, chain: WalletChain.sol)
                    await payoutWalletViewModel.fetchPayoutWallet()
                    viewModel.presentConnectWalletSheet = false
                }
                
            }
            
        }
        .onOpenURL { url in
            connectWalletProviderViewModel.handleDeepLink(url)
        }
        .sheet(isPresented: $viewModel.presentConnectWalletSheet) {
            
            #if os(iOS)
            ConnectWalletNavigationStack(
                api: api,
                presentConnectWalletSheet: $viewModel.presentConnectWalletSheet
            )
            .presentationDetents([.height(264)])
            
            #elseif os(macOS)
            VStack {
                
                Spacer().frame(height: 16)
                
                HStack {
                    Text("Connect external wallet")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                    Spacer()
                    Button(action: {
                        viewModel.presentConnectWalletSheet = false
                    }) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
             
                EnterWalletAddressView(
                    onSuccess: {
                        viewModel.presentConnectWalletSheet = false
                    },
                    api: api
                )
                
                Spacer().frame(height: 16)
                
            }
            #endif
            
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    Task {
                        await refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(accountWalletsViewModel.isCreatingWallet || accountWalletsViewModel.isLoadingTransferStats || accountWalletsViewModel.isLoadingAccountWallets || payoutWalletViewModel.isFetchingPayoutWallet || payoutWalletViewModel.isUpdatingPayoutWallet)
            }
        }
        #endif
        .environmentObject(connectWalletProviderViewModel)
    }
    
    private func refresh() async -> Void {
        
        async let fetchWallets: Void = accountWalletsViewModel.fetchAccountWallets()
        async let fetchPayments: Void = accountPaymentsViewModel.fetchPayments()
        async let fetchTransferStats: Void = accountWalletsViewModel.fetchTransferStats()
        async let fetchReferralLink: Void = referralLinkViewModel.fetchReferralLink()
        
        // Wait for all tasks to complete
        (_, _, _, _) = await (fetchWallets, fetchPayments, fetchTransferStats, fetchReferralLink)
        
    }
}

struct WalletsHeader: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var unpaidMegaBytes: String
    var netAccountPoints: Double
    var payoutPoints: Double
    var multiplierPoints: Double
    var referralPoints: Double
    // var totalReferrals: Int
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    
    var body: some View {
        VStack {
            
            Spacer().frame(height: 16)
            
            VStack(spacing: 0) {
                
                HStack {
                    
                    VStack {
                        HStack {
                            UrLabel(text: "Unpaid data provided")
                            Spacer()
                        }
                        
                        HStack {
                            Text(unpaidMegaBytes)
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                            Spacer()
                        }
                    }
                    
                    Spacer()
                    
                }
                
                Divider()
                
                Spacer().frame(height: 8)
                
                HStack {
                 
                    VStack {
                        HStack {
                            UrLabel(text: "Total referrals")
                            Spacer()
                        }
                        
                        ReferralShareLink(referralLinkViewModel: referralLinkViewModel) {
                            HStack {
                                Text("\(referralLinkViewModel.totalReferrals)")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                                Spacer()
                            }
                        }
                    }
                    
                    Spacer()
                    
                }
                
            }
            .padding(.top)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)
            
            Spacer().frame(height: 8)
            
            HStack {
                Text("Payouts occur every Sunday at 00:00 UTC, and require meeting a minimum USDC threshold.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                
                Spacer()
            }
            
            Spacer().frame(height: 8)
            

            
            
        }
        .padding(.horizontal)
    }
    
}

//#Preview {
//    
//    let themeManager = ThemeManager.shared
//    
//    WalletsView(
//        navigate: {_ in},
//        referralLinkViewModel: ReferralLinkViewModel()
//    )
//        .environmentObject(themeManager)
//        .background(themeManager.currentTheme.backgroundColor)
//}
