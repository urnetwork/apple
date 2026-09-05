//
//  EarningsView.swift
//  URnetwork
//
//  The points-first Earnings screen. Points are URnetwork's own system and
//  always the headline: the total, the breakdown and the per-epoch history.
//  Connecting a Bittensor coldkey adds the subnet layer: the history rows gain
//  SN25α, the unclaimed tile appears and claims go straight from this device
//  to the settlement vault. Alpha is not retroactive.
//

import SwiftUI
import URnetworkSdk

struct EarningsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var throughputStore: ThroughputStore
    @EnvironmentObject var deviceManager: DeviceManager

    let navigate: (AccountNavigationPath) -> Void
    @ObservedObject var accountPointsStore: AccountPointsStore
    let networkReliabilityWindow: SdkReliabilityWindow?
    let fetchNetworkReliability: () async -> Void
    @ObservedObject var viewModel: EarningsViewModel

    @StateObject private var connectFlow: ConnectBittensorWalletFlow
    @State private var presentConnectSheet = false
    @State private var presentClaimSheet = false

    init(
        navigate: @escaping (AccountNavigationPath) -> Void,
        accountPointsStore: AccountPointsStore,
        networkReliabilityWindow: SdkReliabilityWindow?,
        fetchNetworkReliability: @escaping () async -> Void,
        viewModel: EarningsViewModel
    ) {
        self.navigate = navigate
        self.accountPointsStore = accountPointsStore
        self.networkReliabilityWindow = networkReliabilityWindow
        self.fetchNetworkReliability = fetchNetworkReliability
        self.viewModel = viewModel
        _connectFlow = StateObject(wrappedValue: ConnectBittensorWalletFlow(
            client: viewModel.client,
            connect: { address, signature, message in
                try await viewModel.connectWallet(coldkeySs58: address, signature: signature, message: message)
            }
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                AccountPointsBreakdown(
                    netPoints: accountPointsStore.netPoints,
                    providingPoints: accountPointsStore.providingPoints,
                    referralPoints: accountPointsStore.referralPoints,
                    multiplierPoints: accountPointsStore.multiplierPoints,
                    reliabilityPoints: accountPointsStore.reliabilityPoints
                )

                if let head = viewModel.head, viewModel.showsTop200Tile {
                    Top200Tile(head: head)
                }

                BittensorWalletCard(
                    wallet: viewModel.wallet,
                    shortAddress: viewModel.client.shortSs58,
                    connect: {
                        connectFlow.reset()
                        presentConnectSheet = true
                    }
                )

                if viewModel.hasWallet {
                    UnclaimedAlphaTile(
                        totalClaimableRao: viewModel.totalClaimableRao,
                        claimableEpochs: viewModel.claimableClaims.count,
                        claim: {
                            viewModel.resetClaimProgress()
                            presentClaimSheet = true
                        }
                    )
                }

                historySection

                providerCard
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
            .tabletReadableColumn()
        }
        .refreshable {
            await refresh()
        }
        .task {
            if !viewModel.loadedOnce {
                await refresh()
            }
        }
        .onAppear {
            connectFlow.openBridge = { message in
                connectWalletProviderViewModel.openBittensorConnectWallet(message: message)
            }
            connectFlow.onConnected = { _ in
                presentConnectSheet = false
                snackbarManager.showSnackbar(message: String(localized: "Connected"))
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheet(isPresented: $presentConnectSheet, onDismiss: {
            connectFlow.reset()
        }) {
            ConnectBittensorWalletSheet(
                flow: connectFlow,
                dismiss: { presentConnectSheet = false }
            )
            .environmentObject(themeManager)
            #if os(iOS)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .frame(minWidth: 460, minHeight: 320)
            #endif
        }
        .sheet(isPresented: $presentClaimSheet) {
            ClaimAlphaSheet(
                viewModel: viewModel,
                dismiss: { presentClaimSheet = false }
            )
            .environmentObject(themeManager)
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .frame(minWidth: 480, minHeight: 560)
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
                .disabled(viewModel.isLoading || accountPointsStore.isLoading)
            }
        }
        #endif
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                if viewModel.hasWallet {
                    Text(verbatim: SnAlpha.symbol)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }
            .padding(.horizontal, 4)
            Spacer().frame(height: 8)
            if viewModel.epochs.isEmpty {
                HStack {
                    if viewModel.isLoading && !viewModel.loadedOnce {
                        ProgressView()
                    } else {
                        Text("No epochs yet. Points appear after your first finalized epoch.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    Spacer()
                }
                .padding()
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(12)
            } else {
                let claimByEpoch = viewModel.claimByEpoch
                VStack(spacing: 0) {
                    ForEach(viewModel.epochs) { epoch in
                        EpochHistoryRow(
                            epoch: epoch,
                            claim: claimByEpoch[epoch.epoch],
                            showsAlpha: viewModel.hasWallet,
                            formatAlpha: { viewModel.client.formatAlpha(rao: $0) },
                            formatShareBps: viewModel.client.formatShareBps
                        )
                        if epoch.id != viewModel.epochs.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(12)
            }
        }
    }

    private var providerCard: some View {
        VStack(spacing: 0) {
            // provider statistics follow the provide mode: with providing off
            // the reliability chart hides and the section says so, the same
            // gate and message as the stats section
            if deviceManager.provideControlMode != .Never && throughputStore.hasProviderStats {
                NetworkReliabilityView(
                    reliabilityWindow: networkReliabilityWindow
                )
                Divider()
                Spacer().frame(height: 12)
            }
            ProviderStatsSection(navigate: navigate)
        }
        .padding(.top)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private func refresh() async {
        async let earnings: Void = viewModel.refresh()
        async let points: Void = accountPointsStore.fetchAccountPoints()
        async let reliability: Void = fetchNetworkReliability()
        (_, _, _) = await (earnings, points, reliability)
    }

    /// The ur.io wallet bridge returns the coldkey and its signature over the
    /// connect challenge as a deep link.
    private func handleDeepLink(_ url: URL) {
        guard presentConnectSheet else {
            return
        }
        connectWalletProviderViewModel.handleDeepLink(
            url,
            onSignature: { signature in
                guard let address = connectWalletProviderViewModel.connectedPublicKey else {
                    connectFlow.handleBridgeError(WalletDeepLinkError.missingParams)
                    return
                }
                Task {
                    await connectFlow.handleBridgeReturn(address: address, signature: signature)
                }
            },
            onError: { error in
                connectFlow.handleBridgeError(error)
            }
        )
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    let client = EarningsPreviewClient(
        wallet: nil,
        head: SnHeadInfo(eligible: true, score: 12, floor: 10, rankEstimate: 143, cutoff: 200, bound: false, hotkey: "", uid: 0, rank: 0, epoch: 42, source: "server"),
        epochs: [
            AccountEpochInfo(epoch: 42, startMillis: 1_756_000_000_000, endMillis: 1_756_600_000_000, points: 1234.5, shareBps: 71),
            AccountEpochInfo(epoch: 41, startMillis: 1_755_400_000_000, endMillis: 1_756_000_000_000, points: 980, shareBps: 65),
        ]
    )
    EarningsView(
        navigate: { _ in },
        accountPointsStore: AccountPointsStore(api: nil),
        networkReliabilityWindow: nil,
        fetchNetworkReliability: {},
        viewModel: EarningsViewModel(client: client)
    )
    .environmentObject(themeManager)
    .environmentObject(ConnectWalletProviderViewModel())
    .environmentObject(UrSnackbarManager())
    .background(themeManager.currentTheme.backgroundColor)
}
