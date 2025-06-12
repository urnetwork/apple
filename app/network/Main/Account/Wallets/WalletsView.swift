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
    var api: SdkApi?
    var netAccountPoints: Int
    var fetchAccountPoints: () async -> Void
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    @StateObject private var viewModel: ViewModel = ViewModel()
    
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
                            referralLinkViewModel: referralLinkViewModel
                        )
                        
                        PopulatedWalletsView(
                            navigate: navigate,
                            isSeekerOrSagaHolder: accountWalletsViewModel.isSeekerOrSagaHolder,
                            presentConnectWalletSheet: $viewModel.presentConnectWalletSheet,
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
            
            // Wait for all tasks to complete
            (_, _, _, _, _) = await (fetchWallets, fetchPayments, fetchTransferStats, fetchAccountPoints, fetchReferralLink)

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
    var netAccountPoints: Int
    // var totalReferrals: Int
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    
    var body: some View {
        VStack {
            
            Spacer().frame(height: 16)
            
            VStack(spacing: 0) {
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
                    
                    VStack {
                        HStack {
                            UrLabel(text: "Total account points")
                            Spacer()
                        }
                        HStack {
                            Text("\(netAccountPoints)")
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                            Spacer()
                        }
                    }
                    
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
                Text("Payouts occur every two weeks, and require a minimum amount to receive a payout.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                
                Spacer()
            }
            
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
