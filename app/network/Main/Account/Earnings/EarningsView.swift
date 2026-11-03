//
//  EarningsView.swift
//  URnetwork
//
//  The points-first Earnings screen. Points are URnetwork's own system and
//  always the headline: the total, the breakdown and the per-epoch history.
//  Connecting a Bittensor coldkey adds the subnet layer: the history rows gain
//  SN25α, the unclaimed tile appears and claims go straight from this device
//  to the settlement vault. The settlement v2 balances show in a tile of
//  their own beside it, with their own claim. The network payout consent names
//  the coldkey one signature by the network's owner pays every provider of the
//  network to. Alpha is not retroactive. USDC
//  payouts continue to a Solana wallet until the migration to Bittensor is
//  complete; the wallet options next to the Bittensor call connect it. The
//  payout consent card sits above the wallet cards, since a network without a
//  consent is one tap away from earning (apple/BTEASY.md): the SDK's payout key
//  flow behind it makes the key, and a banner stays while its phrase isn't
//  saved.
//

import SwiftUI
import URnetworkSdk

struct EarningsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectWalletProviderViewModel: ConnectWalletProviderViewModel
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var throughputStore: ThroughputStore
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @EnvironmentObject var providerStatusStore: ProviderStatusStore

    let navigate: (AccountNavigationPath) -> Void
    @ObservedObject var accountPointsStore: AccountPointsStore
    let networkReliabilityWindow: SdkReliabilityWindow?
    let fetchNetworkReliability: () async -> Void
    @ObservedObject var viewModel: EarningsViewModel
    @ObservedObject var usdcViewModel: UsdcWalletsViewModel
    /// the jwt's claim or the server's: a guest gets no key
    let isGuest: Bool

    @StateObject private var connectFlow: ConnectBittensorWalletFlow
    @StateObject private var solanaFlow: ConnectSolanaWalletFlow
    @StateObject private var consentFlow: NetworkConsentFlow
    @StateObject private var keyModel: BittensorKeyModel
    @State private var presentConnectSheet = false
    @State private var presentSolanaSheet = false
    @State private var presentClaimSheet = false
    @State private var presentLedgerClaimSheet = false
    @State private var presentConsentSheet = false
    /// the consent sheet opened from Change wallet, which offers a key on this
    /// device too; Use a wallet I already have opens it as it always was
    @State private var consentSheetOffersKey = false
    /// Create a key on this device was tapped in that sheet: the one tap, with
    /// its warning, once the sheet is gone
    @State private var createKeyAfterConsentSheet = false
    @State private var presentRelayClaimSheet = false
    // the Top 200 tile is in the stack: a Claim on Earnings scroll waits for it
    @State private var top200TileShown = false

    init(
        navigate: @escaping (AccountNavigationPath) -> Void,
        accountPointsStore: AccountPointsStore,
        networkReliabilityWindow: SdkReliabilityWindow?,
        fetchNetworkReliability: @escaping () async -> Void,
        viewModel: EarningsViewModel,
        usdcViewModel: UsdcWalletsViewModel,
        consentClient: NetworkConsentClient,
        isGuest: Bool = false,
        makeKeyFlow: @escaping () -> BittensorKeyFlowing = { BittensorKeyPreviewFlow() }
    ) {
        self.navigate = navigate
        self.accountPointsStore = accountPointsStore
        self.networkReliabilityWindow = networkReliabilityWindow
        self.fetchNetworkReliability = fetchNetworkReliability
        self.viewModel = viewModel
        self.usdcViewModel = usdcViewModel
        self.isGuest = isGuest
        _keyModel = StateObject(wrappedValue: BittensorKeyModel(flow: makeKeyFlow()))
        _solanaFlow = StateObject(wrappedValue: ConnectSolanaWalletFlow(client: usdcViewModel.client))
        _connectFlow = StateObject(wrappedValue: ConnectBittensorWalletFlow(
            client: viewModel.client,
            connect: { address, signature, message in
                try await viewModel.connectWallet(coldkeySs58: address, signature: signature, message: message)
            }
        ))
        _consentFlow = StateObject(wrappedValue: NetworkConsentFlow(client: consentClient))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {

                    // until the key's phrase is saved
                    if keyModel.card.backupReminder {
                        BittensorKeyBackupBanner(open: keyModel.openKeyScreen)
                    }

                    // the payout card leads while it needs action: no consent,
                    // or setup cut short
                    if keyModel.card.showsKeyPath {
                        payoutCard
                    }

                    AccountPointsBreakdown(
                        netPoints: accountPointsStore.netPoints,
                        providingPoints: accountPointsStore.providingPoints,
                        referralPoints: accountPointsStore.referralPoints,
                        multiplierPoints: accountPointsStore.multiplierPoints,
                        reliabilityPoints: accountPointsStore.reliabilityPoints,
                        load: accountPointsStore.load,
                        retry: {
                            Task {
                                await accountPointsStore.fetchAccountPoints()
                            }
                        },
                        payoutLine: viewModel.payoutLine(
                            nowMillis: Int64(Date().timeIntervalSince1970 * 1000),
                            formatTime: { SnPayoutLine.formatTime($0) },
                            localKeyPaid: keyModel.card.paysKeyOnThisDevice
                        ),
                        claim: {
                            viewModel.resetClaimProgress()
                            presentClaimSheet = true
                        },
                        setColdkey: {
                            connectFlow.reset()
                            presentConnectSheet = true
                        }
                    )

                    if let tile = viewModel.top200Tile {
                        Top200Tile(
                            tile: tile,
                            sign: {
                                navigate(.top200Sign(nil))
                            },
                            seeBoard: {
                                deepLinkRouter.openProtocolLeaderboard()
                            }
                        )
                        .id(EarningsScrollAnchor.top200)
                        .onAppear {
                            top200TileShown = true
                            scrollToTop200IfAsked(proxy)
                        }
                        .onDisappear {
                            top200TileShown = false
                        }
                    }

                    if !keyModel.card.showsKeyPath {
                        payoutCard
                    }

                    BittensorWalletCard(
                        wallet: viewModel.wallet,
                        localKey: BittensorWalletCardLocalKey(card: keyModel.card),
                        shortAddress: viewModel.client.shortSs58,
                        connect: {
                            connectFlow.reset()
                            presentConnectSheet = true
                        },
                        pendingUsd: usdcViewModel.showsPendingLine ? usdcViewModel.pendingUsd : nil,
                        connectSolana: {
                            solanaFlow.reset()
                            presentSolanaSheet = true
                        },
                        loadFailed: viewModel.walletLoadFailed,
                        retry: {
                            Task {
                                await viewModel.refresh()
                            }
                        }
                    )

                    // the wallet USDC payouts go to until the migration to Bittensor
                    if usdcViewModel.loadedOnce, let wallet = usdcViewModel.payoutWallet {
                        SolanaWalletCard(
                            wallet: wallet,
                            pendingUsd: usdcViewModel.pendingUsd,
                            isRemoving: usdcViewModel.isRemoving,
                            remove: {
                                usdcViewModel.walletQueuedForRemoval = wallet
                            }
                        )
                    } else if usdcViewModel.loadFailed {
                        // unread is not "no payout wallet"
                        SolanaWalletLoadFailedCard(retry: {
                            Task {
                                await usdcViewModel.refresh()
                            }
                        })
                    }

                    if viewModel.hasWallet {
                        // the first claim tile carries the claim card's disclaimer
                        UnclaimedAlphaTile(
                            totalClaimableRao: viewModel.totalClaimableRao,
                            claimableEpochs: viewModel.claimableClaims.count,
                            claim: {
                                viewModel.resetClaimProgress()
                                presentClaimSheet = true
                            },
                            fundsDisclaimer: keyModel.card.claimFundsDisclaimer
                        )
                    }

                    // settlement v2, separate from the v1 claims above: URnetwork
                    // claims it for every consented network (the claim relay), and
                    // the device's own claim stays as the fallback
                    if let ledgerTile = viewModel.ledgerTileWithRelay {
                        SnLedgerTile(
                            presentation: ledgerTile,
                            claim: {
                                viewModel.resetLedgerClaimProgress()
                                presentLedgerClaimSheet = true
                            },
                            relay: viewModel.claimStatus,
                            claimNow: {
                                viewModel.resetClaimNow()
                                presentRelayClaimSheet = true
                            },
                            selfClaim: {
                                viewModel.resetLedgerClaimProgress()
                                presentLedgerClaimSheet = true
                            },
                            fundsDisclaimer: viewModel.hasWallet ? SdkBittensorFundsDisclaimerNone : keyModel.card.claimFundsDisclaimer
                        )
                    }

                    historySection

                    providerCard
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
                .tabletReadableColumn()
            }
            // the Protocol leaderboard's Claim on Earnings lands at the tile
            .onReceive(deepLinkRouter.$pendingEarningsTop200Scroll) { pending in
                if pending {
                    scrollToTop200IfAsked(proxy)
                }
            }
            // Back up first, and the reminder's notification, open the Key screen
            .onReceive(deepLinkRouter.$pendingEarningsKeyScreen) { pending in
                if pending, deepLinkRouter.consumeEarningsKeyScreen() {
                    keyModel.openKeyScreen()
                }
            }
        }
        .onDisappear {
            // a scroll the tile never showed for is not kept for a later visit
            deepLinkRouter.cancelEarningsTop200Scroll()
        }
        .refreshable {
            await refresh()
        }
        .task {
            if !viewModel.loadedOnce {
                await refresh()
            } else {
                // the view model outlives this visit, the consent flow does
                // not: a new visit reads the consent again
                await consentFlow.refreshStatus()
                syncKeyModelWithEarnings()
            }
        }
        .onChange(of: isGuest) { isGuest in
            keyModel.setGuest(isGuest)
        }
        .onAppear {
            // the key's flow works from the same consent read, and a consent
            // it got accepted is read again with everything it changes
            consentFlow.onStatusRead = { status, fromEpoch in
                keyModel.consentRead(status, fromEpoch: fromEpoch)
            }
            keyModel.onLinked = {
                Task {
                    await refresh()
                }
            }
            keyModel.visit(isGuest: isGuest)
            connectFlow.onConnected = { _ in
                presentConnectSheet = false
                snackbarManager.showSnackbar(message: String(localized: "Connected"))
            }
            // the card shows the new consent
            consentFlow.onSigned = {
                presentConsentSheet = false
            }
            solanaFlow.openWallet = { app in
                switch app {
                case .phantom:
                    return connectWalletProviderViewModel.connectPhantomWallet(onOpenFailed: showSolanaWalletOpenFailed)
                case .solflare:
                    return connectWalletProviderViewModel.connectSolflareWallet(onOpenFailed: showSolanaWalletOpenFailed)
                }
            }
            solanaFlow.onConnected = { _ in
                presentSolanaSheet = false
                Task {
                    await usdcViewModel.refresh()
                    snackbarManager.showSnackbar(message: String(localized: "Payout wallet updated"))
                }
            }
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheetOffTheFold(isPresented: $presentConnectSheet, onDismiss: {
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
        .sheetOffTheFold(isPresented: $presentSolanaSheet, onDismiss: {
            solanaFlow.reset()
        }) {
            ConnectSolanaWalletSheet(
                flow: solanaFlow,
                dismiss: { presentSolanaSheet = false }
            )
            .environmentObject(themeManager)
            .environmentObject(connectWalletProviderViewModel)
            .environmentObject(snackbarManager)
            // linking cannot be abandoned half way: no swipe on iOS, no
            // Escape on macOS
            .interactiveDismissDisabled(solanaFlow.stage == .connecting)
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .frame(minWidth: 460, minHeight: 320)
            #endif
        }
        .alert(
            "Remove wallet",
            isPresented: Binding(
                get: { usdcViewModel.walletQueuedForRemoval != nil },
                set: { isPresented in
                    if !isPresented {
                        usdcViewModel.walletQueuedForRemoval = nil
                    }
                }
            ),
            presenting: usdcViewModel.walletQueuedForRemoval
        ) { wallet in
            Button("Remove", role: .destructive) {
                Task {
                    await removeSolanaWallet(wallet)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // removing the payout wallet makes another of the network's Solana
            // or Polygon wallets the payout wallet when there is one (the
            // server picks it) and holds USDC payouts when there is none: one
            // line for both
            Text("USDC payouts move to another of your Solana or Polygon wallets, or are held until you connect one.")
        }
        .sheetOffTheFold(isPresented: $presentClaimSheet) {
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
        .sheetOffTheFold(isPresented: $presentLedgerClaimSheet) {
            ClaimLedgerSheet(
                viewModel: viewModel,
                dismiss: { presentLedgerClaimSheet = false }
            )
            .environmentObject(themeManager)
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
        .sheetOffTheFold(isPresented: $presentRelayClaimSheet) {
            ClaimRelaySheet(
                viewModel: viewModel,
                fundsDisclaimer: keyModel.flow.fundsDisclaimer(at: SdkBittensorFundsDisclaimerPlaceClaimSheet),
                selfClaim: {
                    presentRelayClaimSheet = false
                    viewModel.resetLedgerClaimProgress()
                    presentLedgerClaimSheet = true
                },
                dismiss: { presentRelayClaimSheet = false }
            )
            .environmentObject(themeManager)
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
        .sheetOffTheFold(isPresented: $presentConsentSheet, onDismiss: {
            consentFlow.reset()
            if createKeyAfterConsentSheet {
                createKeyAfterConsentSheet = false
                keyModel.setUpPayouts()
            }
        }) {
            NetworkConsentSheet(
                flow: consentFlow,
                connector: consentFlow.connector,
                dismiss: { presentConsentSheet = false },
                createKey: changeWalletCreatesKey,
                createKeyDisclaimer: keyModel.flow.fundsDisclaimer(at: SdkBittensorFundsDisclaimerPlaceChangeWallet)
            )
            .environmentObject(themeManager)
            // a signed consent on its way to the server is not abandoned
            .interactiveDismissDisabled(consentFlow.stage == .submitting)
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #elseif os(macOS)
            .frame(minWidth: 460, minHeight: 320)
            #endif
        }
        // leaving discards a phrase that is only in memory; a signed consent on
        // its way is not abandoned
        .sheetOffTheFold(isPresented: Binding(
            get: { keyModel.screen.open },
            set: { presented in
                if !presented {
                    keyModel.closeScreen()
                }
            }
        )) {
            BittensorKeyScreen(model: keyModel, dismiss: keyModel.closeScreen)
                .environmentObject(themeManager)
                .interactiveDismissDisabled(keyModel.screen.busy)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #elseif os(macOS)
                .frame(minWidth: 480, minHeight: 560)
                #endif
        }
        // a key replaces the payout wallet from the next epoch: warned first,
        // and it is never the default
        .alert(
            "Replace your payout wallet?",
            isPresented: Binding(
                get: { keyModel.pendingReplacement != nil },
                set: { presented in
                    if !presented {
                        keyModel.pendingReplacement = nil
                    }
                }
            ),
            presenting: keyModel.pendingReplacement
        ) { _ in
            Button("Replace payout wallet", role: .destructive) {
                keyModel.replacementConfirmed()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("From the next epoch, your network's earnings go to a new key on this device. Earlier earnings stay on \(viewModel.client.shortSs58(keyModel.card.address)). The network admin gets an email about this change.")
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

    /// Change wallet's offer of a key on this device, while the flow offers one.
    private var changeWalletCreatesKey: (() -> Void)? {
        guard consentSheetOffersKey, keyModel.card.offersSetUp else {
            return nil
        }
        return {
            createKeyAfterConsentSheet = true
            presentConsentSheet = false
        }
    }

    /// The network's payout consent, with or without a coldkey on this device:
    /// without one, no provider of the network is paid.
    private var payoutCard: some View {
        NetworkConsentCard(
            status: consentFlow.status,
            hasNetworkCredential: consentFlow.hasNetworkCredential,
            shortAddress: viewModel.client.shortSs58,
            sign: {
                consentFlow.reset()
                consentSheetOffersKey = true
                presentConsentSheet = true
            },
            retry: {
                Task {
                    await consentFlow.refreshStatus()
                }
            },
            key: keyModel.card,
            keyActions: BittensorKeyCardActions(
                setUp: keyModel.setUpPayouts,
                saveFirst: keyModel.saveFirst,
                useWallet: {
                    consentFlow.reset()
                    consentSheetOffersKey = false
                    presentConsentSheet = true
                },
                finishSetup: keyModel.finishSetup,
                openKeyScreen: keyModel.openKeyScreen,
                reload: {
                    keyModel.visit(isGuest: isGuest)
                }
            )
        )
    }

    /// Claim on Earnings asked for the Top 200 tile: once the tile is in the
    /// stack, the screen scrolls to it, and only once.
    private func scrollToTop200IfAsked(_ proxy: ScrollViewProxy) {
        guard top200TileShown, deepLinkRouter.consumeEarningsTop200Scroll() else {
            return
        }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(EarningsScrollAnchor.top200, anchor: .top)
            }
        }
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
                    switch viewModel.historyLoad {
                    case .loading:
                        ProgressView()
                    case .failed:
                        SectionLoadFailedView(retry: {
                            Task {
                                await viewModel.refresh()
                            }
                        })
                    case .loaded:
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
            if providerStatisticsVisible(
                provideControlMode: deviceManager.provideControlMode,
                hasProviderStats: throughputStore.hasProviderStats
            ) {
                NetworkReliabilityView(
                    reliabilityWindow: networkReliabilityWindow
                )
                Divider()
                Spacer().frame(height: 12)
            }
            // the extender statistics, above the provider statistics while
            // those show and the role runs (EXTENDER.md O8)
            if extenderStatsVisible {
                ExtenderStatsSection()
                Spacer().frame(height: 12)
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

    /// The provider gate above and the role running, which follows the pushed
    /// status and never the throughput tick (EXTENDER.md O4, O8).
    private var extenderStatsVisible: Bool {
        extenderStatsSectionVisible(
            provideControlMode: deviceManager.provideControlMode,
            hasProviderStats: throughputStore.hasProviderStats,
            extenderRunning: deviceManager.extenderProvideStatus.enabled
        )
    }

    private func refresh() async {
        providerStatusStore.refresh()
        async let earnings: Void = viewModel.refresh()
        async let points: Void = accountPointsStore.fetchAccountPoints()
        async let reliability: Void = fetchNetworkReliability()
        async let usdc: Void = usdcViewModel.refresh()
        async let consent: Void = consentFlow.refreshStatus()
        (_, _, _, _, _) = await (earnings, points, reliability, usdc, consent)
        syncKeyModelWithEarnings()
    }

    /// What the key's flow decides from the earnings: "Payouts start next
    /// epoch", the Top 200 warning, and the one reminder.
    private func syncKeyModelWithEarnings() {
        keyModel.setTop200Registered(viewModel.top?.me.rankedRow?.fleets.isEmpty == false)
        keyModel.earningsRead(
            schedule: viewModel.schedule,
            claimable: viewModel.totalClaimableRao > 0 || viewModel.ledgerClaimableRao > 0 || (viewModel.claimStatus?.claimableRao ?? 0) > 0
        )
    }

    /// The wallets come back as deep links. Phantom and Solflare (or the ur.io
    /// bridge driving their extensions) return the Solana public key through
    /// urnetwork://phantom-connect or urnetwork://solflare-connect; the ur.io
    /// wallet bridge returns the coldkey and its signature over the connect
    /// challenge, or over the payout consent. A link reaches only the flow it
    /// belongs to, and only while that flow's sheet is up.
    private func handleDeepLink(_ url: URL) {
        switch EarningsWalletLink.route(url, solanaSheetUp: presentSolanaSheet, bittensorSheetUp: presentConnectSheet, consentSheetUp: presentConsentSheet) {
        case .solana:
            connectWalletProviderViewModel.handleDeepLink(
                url,
                onPublicKeyRetrieved: { publicKey, provider in
                    // the payout wallet needs only the key; sign-in must not
                    // reuse this session
                    connectWalletProviderViewModel.forgetConnection()
                    Task {
                        await solanaFlow.handleWalletReturn(publicKey: publicKey, provider: provider)
                    }
                },
                onError: { error in
                    solanaFlow.handleWalletError(error)
                }
            )
        case .bittensor:
            handleBittensorDeepLink(url, connector: connectFlow.connector)
        case .consent:
            handleBittensorDeepLink(url, connector: consentFlow.connector)
        case nil:
            return
        }
    }

    /// The bridge hand-back goes to the SDK session, which ignores a return
    /// for another flow (purpose) or another challenge.
    private func handleBittensorDeepLink(_ url: URL, connector: BittensorWalletConnector) {
        Task {
            await connector.handleBridgeReturn(url)
        }
    }

    /// The wallet app did not open: back to the chooser.
    private func showSolanaWalletOpenFailed() {
        solanaFlow.reset()
        snackbarManager.showSnackbar(message: String(localized: "Couldn't open wallet. Please install it and try again."))
    }

    private func removeSolanaWallet(_ wallet: UsdcWalletInfo) async {
        switch await usdcViewModel.removeWallet(wallet.id) {
        case .failure(let error):
            snackbarManager.showSnackbar(message: ConnectSolanaWalletFlow.errorMessage(for: error))
        case .success(let promoted?):
            // another wallet became the payout wallet: say where payouts go now
            snackbarManager.showSnackbar(message: String(localized: "Payouts now go to \(SnAlpha.shortSs58(promoted.address))."))
        case .success(nil):
            break
        }
    }
}

/// The places on the Earnings screen a link scrolls to.
enum EarningsScrollAnchor: Hashable {
    /// the Top 200 tile (Claim on Earnings)
    case top200
}

/// Which connect sheet a wallet deep link belongs to: Phantom and Solflare
/// (or the ur.io bridge driving their extensions) return to the Solana sheet,
/// the ur.io Bittensor bridge to the Bittensor sheet or the payout consent
/// sheet, whichever is up. A link whose sheet is not up belongs to none.
enum EarningsWalletLink: Equatable {
    case solana
    case bittensor
    case consent

    static func route(_ url: URL, solanaSheetUp: Bool, bittensorSheetUp: Bool, consentSheetUp: Bool = false) -> EarningsWalletLink? {
        switch url.host ?? "" {
        case "phantom-connect", "solflare-connect":
            return solanaSheetUp ? .solana : nil
        case "bittensor-sign-message":
            if consentSheetUp {
                return .consent
            }
            return bittensorSheetUp ? .bittensor : nil
        default:
            return nil
        }
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    let board = SnTopPreviewClient()
    let client = EarningsPreviewClient(
        wallet: nil,
        top: SnTopMeResultInfo(snapshot: board.snapshot, me: board.me),
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
        viewModel: EarningsViewModel(client: client),
        usdcViewModel: UsdcWalletsViewModel(
            client: UsdcWalletsPreviewClient(startLinked: true, pendingUsdNanoCents: 3_870_000_000)
        ),
        consentClient: NetworkConsentPreviewClient()
    )
    .environmentObject(themeManager)
    .environmentObject(ConnectWalletProviderViewModel())
    .environmentObject(UrSnackbarManager())
    .environmentObject(DeepLinkRouter())
    .background(themeManager.currentTheme.backgroundColor)
}
