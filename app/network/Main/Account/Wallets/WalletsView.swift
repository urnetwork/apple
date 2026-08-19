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
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    
    let navigate: (AccountNavigationPath) -> Void
    let api: UrApiServiceProtocol
    let netAccountPoints: Double
    let payoutPoints: Double
    let multiplierPoints: Double
    let referralPoints: Double
    let reliabilityPoints: Double
    let fetchAccountPoints: () async -> Void
    let networkReliabilityWindow: SdkReliabilityWindow?
    let fetchNetworkReliability: () async -> Void
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    @StateObject private var viewModel: ViewModel
//    @StateObject private var networkReliabilityStore: NetworkReliabilityStore
    
    init(
        navigate: @escaping (AccountNavigationPath) -> Void,
        api: UrApiServiceProtocol,
        netAccountPoints: Double,
        payoutPoints: Double,
        multiplierPoints: Double,
        referralPoints: Double,
        reliabilityPoints: Double,
        fetchAccountPoints: @escaping () async -> Void,
        networkReliabilityWindow: SdkReliabilityWindow?,
        fetchNetworkReliability: @escaping () async -> Void,
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
        self.networkReliabilityWindow = networkReliabilityWindow
        self.fetchNetworkReliability = fetchNetworkReliability
        _viewModel = StateObject(wrappedValue: ViewModel())
//        _networkReliabilityStore = StateObject(wrappedValue: NetworkReliabilityStore(api: api))
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
                                navigate: navigate,
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
                            navigate: navigate,
                            unpaidMegaBytes: accountWalletsViewModel.unpaidDataFormatted,
                            netAccountPoints: netAccountPoints,
                            payoutPoints: payoutPoints,
                            multiplierPoints: multiplierPoints,
                            referralPoints: referralPoints,
                            networkReliabilityWindow: networkReliabilityWindow,
                            referralLinkViewModel: referralLinkViewModel,
                        )
                        
                        PopulatedWalletsView(
                            navigate: navigate,
                            isSeekerOrSagaHolder: accountWalletsViewModel.isSeekerOrSagaHolder,
                            netPoints: netAccountPoints,
                            payoutPoints: payoutPoints,
                            referralPoints: referralPoints,
                            multiplierPoints: multiplierPoints,
                            reliabilityPoints: reliabilityPoints,
                            // networkReliabilityWindow: networkReliabilityStore.reliabilityWindow,
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
            async let fetchNetworkReliability: Void = fetchNetworkReliability()
            
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
        .onOpenURL { url in
            guard viewModel.presentConnectWalletSheet else {
                return
            }

            connectWalletProviderViewModel.handleDeepLink(
                url,
                onPublicKeyRetrieved: { walletAddress, _ in
                    Task {
                        let result = await accountWalletsViewModel.connectWallet(walletAddress: walletAddress, chain: WalletChain.sol)

                        switch result {
                        case .success:
                            await payoutWalletViewModel.fetchPayoutWallet()
                            viewModel.presentConnectWalletSheet = false
                        case .failure(let error):
                            snackbarManager.showSnackbar(message: String(localized: "There was an error connecting your wallet: \(error.localizedDescription)"))
                        }
                    }
                },
                onError: { _ in
                    snackbarManager.showSnackbar(message: String(localized: "There was an error connecting your wallet."))
                }
            )
        }
        .sheet(isPresented: $viewModel.presentConnectWalletSheet) {
            
            #if os(iOS)
            ConnectWalletNavigationStack(
                api: api,
                presentConnectWalletSheet: $viewModel.presentConnectWalletSheet
            )
            .environmentObject(themeManager)
            .presentationDetents([.height(264)])
            
            #elseif os(macOS)
            // full deeplink connect flow (Phantom / Solflare via the
            // ur.io/wallet-connect bridge, plus manual address entry)
            ConnectWalletNavigationStack(
                api: api,
                presentConnectWalletSheet: $viewModel.presentConnectWalletSheet
            )
            .environmentObject(themeManager)
            .environmentObject(accountWalletsViewModel)
            .environmentObject(connectWalletProviderViewModel)
            .frame(minWidth: 460, minHeight: 320)
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

    var navigate: ((AccountNavigationPath) -> Void)? = nil
    var unpaidMegaBytes: String
    var netAccountPoints: Double
    var payoutPoints: Double
    var multiplierPoints: Double
    var referralPoints: Double
    var networkReliabilityWindow: SdkReliabilityWindow?
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
                
                Divider()

                Spacer().frame(height: 8)

                NetworkReliabilityView(
                    reliabilityWindow: networkReliabilityWindow
                )

                if let navigate = navigate {

                    Divider()

                    Spacer().frame(height: 12)

                    ProviderStatsSection(navigate: navigate)

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

/**
 * Provider statistics: local and blocked traffic relayed for remote
 * clients. Tap to open the provider contract details.
 */
struct ProviderStatsSection: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var throughputStore: ThroughputStore
    @EnvironmentObject var transportSettingsStore: TransportSettingsStore

    let navigate: (AccountNavigationPath) -> Void

    @State private var presentTransportSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                UrLabel(text: "Provider statistics")
                Spacer()
                if throughputStore.hasProviderStats {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.textFaintColor)
                }
            }

            Spacer().frame(height: 8)

            if throughputStore.hasProviderStats {

                TransferChart(
                    points: throughputStore.providerPoints,
                    route: .local,
                    title: "Local",
                    window: throughputStore.windowDuration
                )

                Spacer().frame(height: 12)

                /**
                 * The relayed traffic of the window by the transport this
                 * device used to carry it, under the provider plot. Tap to
                 * open the provider transport settings.
                 */
                TransportDistributionBar(
                    distribution: throughputStore.providerTransportDistribution,
                    action: { presentTransportSettings = true }
                )

                Spacer().frame(height: 12)

                TransferChart(
                    points: throughputStore.providerPoints,
                    route: .block,
                    title: "Blocked",
                    height: 64,  // secondary series — half height
                    window: throughputStore.windowDuration,
                    byteColor: .urCoral,
                    packetColor: .urMutedCoral
                )

            } else {

                Text("Providing is disabled")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textFaintColor)
                    .padding(.bottom, 8)

            }

        }
        .contentShape(Rectangle())
        .onTapGesture {
            if throughputStore.hasProviderStats {
                navigate(.providerContracts)
            }
        }
        .sheet(isPresented: $presentTransportSettings) {
            let transportView = TransportSettingsView(
                kind: .provider,
                settings: transportSettingsStore.providerSettings
            )
            Group {
                #if os(macOS)
                transportView.frame(minWidth: 480, minHeight: 540)
                #else
                transportView
                #endif
            }
            .environmentObject(themeManager)
            .environmentObject(transportSettingsStore)
        }
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
