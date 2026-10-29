//
//  ConnectView-iOS.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/11.
//

import SwiftUI
import URnetworkSdk

#if os(iOS)
struct ConnectView_iOS: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @Environment(\.requestReview) private var requestReview
    // compact widths run the drawer edge to edge behind the tab bar; regular
    // widths split the screen into panes (ConnectArrangement)
    @Environment(\.isRegularWidth) private var isRegularWidth

    @EnvironmentObject var connectViewModel: ConnectViewModel
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter

    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    @ObservedObject private var providerListStore: ProviderListStore
    
    let logout: () -> Void
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let promptMoreDataFlow: () -> Void
    let meanReliabilityWeight: Double
    let isPro: Bool
    // incremented by the tab bar when the connect tab is re-tapped
    var collapseDrawerSignal: Int = 0
    @ObservedObject var providerListSheetViewModel: ProviderListSheetViewModel
    
    @StateObject private var egressContractStatsViewModel: EgressContractStatsViewModel

    @State var displayReconnectTunnel: Bool = false

    @State private var isSheetExpanded = false
    // the one Referrals screen, presented from the drawer's referral row
    @State private var isPresentedReferrals = false
    @State private var isPresentedDataInfo = false
    @State private var sheetDragTranslation: CGFloat = 0
    @State private var presentedStatsSheet: ConnectStatsSheet? = nil
    
    /// Presents the sheet a widget tap asked for, if one is pending.
    private func presentWidgetDestination() {
        guard let destination = deepLinkRouter.consume() else { return }
        switch destination {
        case .providers:
            presentedStatsSheet = .providerLocations
        case .contracts:
            presentedStatsSheet = .clientContracts
        case .connect, .slowInternet:
            // the slow internet Live Activity lands here too: the pill is
            // the whole story
            break
        }
    }

    // whether the expanded sheet's content is scrolled to the very top.
    // at the top, a downward drag closes the sheet instead of rubber-banding
    @State private var sheetScrollAtTop: Bool = true
    @State private var sheetScrollBaseline: CGFloat? = nil

    // The collapsed drawer shows EXACTLY the above-the-fold content — the
    // location row with the connect button — and nothing else. A fixed peek
    // constant cannot do that across devices and font scales, so the peek is
    // measured: the sheet header (handle + divider) height plus the fold
    // marker's offset within the sheet content (Android parity). Until both
    // measurements land, the fallback keeps a sane peek.
    @State private var sheetHeaderHeight: CGFloat = 0
    @State private var sheetFoldMaxY: CGFloat? = nil

    private let sheetMinHeightFallback: CGFloat = 280   // pre-measurement collapsed peek

    // the canvas sizes itself to the room its status line leaves, and the
    // location picker's popover points at the location row
    @State private var statusLineHeight: CGFloat = 20
    @State private var locationRowFrame: CGRect = .zero

    // the standard visible padding between the bottom of the connect button
    // and the top of the tab bar at the collapsed peek — the same 12pt on
    // every device, matching the Android drawer
    private let sheetFoldGap: CGFloat = 12

    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        logout: @escaping () -> Void,
        device: SdkDeviceRemote?,
        providerListSheetViewModel: ProviderListSheetViewModel,
        referralLinkViewModel: ReferralLinkViewModel,
        providerStore: ProviderListStore,
        promptMoreDataFlow: @escaping () -> Void,
        meanReliabilityWeight: Double,
        isPro: Bool,
        collapseDrawerSignal: Int = 0
    ) {
        self.logout = logout
        self.api = api
        self.urApiService = urApiService
        self.providerListSheetViewModel = providerListSheetViewModel
        self.referralLinkViewModel = referralLinkViewModel
        _egressContractStatsViewModel = StateObject(wrappedValue: EgressContractStatsViewModel(device: device))
        self.providerListStore = providerStore

        self.promptMoreDataFlow = promptMoreDataFlow
        self.meanReliabilityWeight = meanReliabilityWeight


        self.isPro = isPro
        self.collapseDrawerSignal = collapseDrawerSignal

        // adds clear button to search providers text field
        UITextField.appearance().clearButtonMode = .whileEditing
    }
    
    /// The selected location's count from the last provider list fetch, not the
    /// copy taken when it was selected.
    private var liveSelectedProviderCount: Int {
        let selected = connectViewModel.selectedProvider
        let fetched = [
            providerListStore.providerCountries,
            providerListStore.providerRegions,
            providerListStore.providerCities,
            providerListStore.providerDevices,
            providerListStore.providerBestSearchMatches,
        ].joined().compactMap { location -> (String, Int)? in
            guard let id = location.connectLocationId?.string() else { return nil }
            return (id, Int(location.providerCount))
        }
        return selectedProviderCount(
            selectedId: selected?.connectLocationId?.string(),
            selectedCount: Int(selected?.providerCount ?? 0),
            fetched: fetched
        )
    }

    var body: some View {
        
        GeometryReader { geometry in

            // the fold of a foldable, flat or folded; the window's full width,
            // under any side bar, picks the arrangement (apple/DUO.md)
            let fold = geometry.windowFold
            let windowWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            let arrangement = SplitLayout.connectArrangement(
                isRegularWidth: isRegularWidth,
                width: windowWidth,
                fold: fold
            )
            let panes = SplitLayout.panes(
                size: geometry.size,
                sideBySide: arrangement == .sideBySide,
                fold: fold
            )

            // the phone drawer extends behind the tab bar. its expanded height
            // is capped by the window, and by the fold in tabletop
            let bottomExtension = geometry.safeAreaInsets.bottom
            let screenHeight = geometry.size.height + bottomExtension
            let sheetExpandedHeight = SplitLayout.drawerExpandedHeight(screenHeight: screenHeight, fold: fold)
            let sheetCollapsedHeight = collapsedSheetHeight(safeAreaBottom: bottomExtension, maxHeight: sheetExpandedHeight)

            ZStack(alignment: .top) {

                splitPanes(arrangement: arrangement, panes: panes, size: geometry.size)

                // the canvas is this one view in every arrangement, so a fold
                // or a resize that changes the arrangement keeps its state
                // and never restarts its animation
                canvasPane(arrangement: arrangement, drawerTop: screenHeight - sheetCollapsedHeight)
                    .frame(
                        width: arrangement == .sideBySide ? geometry.size.width - panes.secondStart : geometry.size.width,
                        height: arrangement == .stacked ? panes.firstEnd : geometry.size.height
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: arrangement == .sideBySide ? .trailing : .top
                    )

                if arrangement == .drawer {
                    drawer(
                        safeAreaBottom: bottomExtension,
                        screenHeight: screenHeight,
                        collapsedHeight: sheetCollapsedHeight,
                        expandedHeight: sheetExpandedHeight
                    )
                }

            }
            .coordinateSpace(name: connectScreenCoordinateSpace)
            .onPreferenceChange(ConnectStatusHeightPreferenceKey.self) { height in
                if 0 < height {
                    statusLineHeight = height
                }
            }
            .onPreferenceChange(ConnectLocationRowFramePreferenceKey.self) { frame in
                locationRowFrame = frame
            }
            // the slow internet pill, 16 pt from the trailing edge and 8 pt
            // below the top safe area (apple/DELAY.md §5.2), at the top right
            // of the connect pane in every arrangement; it observes the
            // transport delay itself, so a reading re-renders only the pill
            .overlay(alignment: .topTrailing) {
                SlowInternetPillOverlay()
                    .padding(.top, 8)
                    .padding(.trailing, 16)
            }
            // the location picker: a sheet at compact width, and at regular
            // width a popover pointing at the location row, in that row's
            // pane and off the fold. One presentation in every arrangement,
            // so the open picker and its search survive a fold or a resize
            .popover(
                isPresented: $providerListSheetViewModel.isPresented,
                attachmentAnchor: .rect(.rect(locationRowFrame)),
                arrowEdge: .top
            ) {
                providerPicker
                    .frame(
                        idealWidth: locationPopoverWidth(arrangement: arrangement, panes: panes, width: geometry.size.width),
                        idealHeight: min(SplitLayout.locationPopoverMaxHeight, geometry.size.height)
                    )
            }
            // statistics and dns detail sheets (store subscription isolated in the modifier)
            .modifier(ConnectStatsSheets(presentedStatsSheet: $presentedStatsSheet))
        // a Home Screen widget tap: provider details or client contracts
        .onReceive(deepLinkRouter.$pending) { _ in
            presentWidgetDestination()
        }
        .onAppear {
            presentWidgetDestination()
        }
        // refresh the provider counts while the home screen shows
        .modifier(HomeLocationsRefresh(providerListStore: providerListStore))
        // referrals: the Account section's screen, unchanged, in a sheet
        .sheetOffTheFold(isPresented: $isPresentedReferrals) {
            ReferralsSheet(
                api: urApiService,
                sdkApi: api,
                referralLinkViewModel: referralLinkViewModel,
                dismiss: { isPresentedReferrals = false }
            )
            .environmentObject(themeManager)
        }
        // "About your data", from the usage bar and the out-of-balance notice
        .dataInfoSheet(isPresented: $isPresentedDataInfo, isPro: isPro)
            // upgrade subscription
            .sheetOffTheFold(isPresented: $connectViewModel.isPresentedUpgradeSheet) {
                // a legacy guest adds a sign-in method to this network
                // first: a plan bought on a guest network is stranded
                GuestPurchaseGate(urApiService: urApiService) {
                    UpgradeSubscriptionSheet(
                        monthlyProduct: subscriptionManager.monthlySubscription,
                        yearlyProduct: subscriptionManager.yearlySubscription,
                        yearlyTrialDays: subscriptionManager.yearlyTrialDays,
                        purchaseUnavailable: { subscriptionManager.reportProductsUnavailable() },
                        purchase: { product in

                            // note: no VPN disconnect around the purchase on iOS —
                            // App Store purchase traffic does not ride the tunnel;
                            // see the A6 note on AppStoreSubscriptionManager.purchase

                            Task {
                                do {
                                    try await subscriptionManager.purchase(
                                        product: product,
                                        onSuccess: {
                                            subscriptionBalanceViewModel.startPolling()
                                        }
                                    )

                                } catch(let error) {
                                    // rendered inline via subscriptionManager.purchaseError
                                    print("error making purchase: \(error)")
                                }


                            }

                        },
                        isPurchasing: subscriptionManager.isPurchasing,
                        purchaseSuccess: subscriptionManager.purchaseSuccess,
                        purchaseConfirmed: deviceManager.isPro,
                        purchasePending: subscriptionManager.purchasePending,
                        purchaseConfirmationTimedOut: subscriptionBalanceViewModel.purchaseConfirmationTimedOut,
                        purchaseError: subscriptionManager.purchaseError,
                        productsLoadFailed: subscriptionManager.fetchProductsError,
                        retryFetchProducts: {
                            subscriptionManager.retryFetchProductsIfNeeded()
                        },
                        restorePurchases: {
                            Task {
                                if await subscriptionManager.restorePurchases() == .restored {
                                    subscriptionBalanceViewModel.startPolling()
                                }
                            }
                        },
                        isRestoringPurchases: subscriptionManager.isRestoringPurchases,
                        restoreMessage: subscriptionManager.restoreResultMessage,
                        showsFreeRefresh: upgradeShowsFreeRefresh(
                            openedByStartConnectBlock: connectViewModel.upgradeOpenedByStartConnectBlock,
                            isPro: isPro
                        ),
                        dismiss: {
                            connectViewModel.isPresentedUpgradeSheet = false
                            // the purchase flags describe ONE attempt; letting them
                            // survive is what showed "You're premium." to a user who
                            // had not actually completed a purchase
                            subscriptionManager.resetPurchaseState()
                        }
                    )
                }
                .environmentObject(themeManager)
            }
            
            .onChange(of: connectViewModel.connectionStatus) { _ in
                checkTunnelStatus()
            }
            .onChange(of: connectViewModel.tunnelConnected) { _ in
                checkTunnelStatus()
            }
            // the auto-disconnect uses the same insufficient balance gate
            // this view renders
            .onAppear {
                updateInsufficientBalanceGuards()
            }
            .onChange(of: isPro) { _ in
                updateInsufficientBalanceGuards()
            }
            .onChange(of: subscriptionBalanceViewModel.isPolling) { _ in
                updateInsufficientBalanceGuards()
            }
            // every balance reading feeds the recovery of a connect the
            // balance blocked (ConnectViewModel.balanceReadingChanged)
            .onChange(of: subscriptionBalanceViewModel.lastWidgetBalanceSnapshot) { _ in
                connectViewModel.balanceReadingChanged()
            }
            .onChange(of: connectViewModel.balanceRecoveryRetryCount) { _ in
                snackbarManager.showSnackbar(message: String(localized: "Data is available again. Reconnecting…"))
            }
            .onChange(of: collapseDrawerSignal) { _ in
                // the connect tab was re-tapped. close the drawer.
                isSheetExpanded = false
            }
        }

    }
    
    /**
     * The panes of the split arrangements. Side by side, the drawer, always
     * expanded, is the statistics pane beside the connect pane. Stacked, it
     * is the pane under the canvas, with the action buttons at its foot.
     * The phone layout's drawer is drawn over the canvas instead.
     */
    @ViewBuilder
    private func splitPanes(arrangement: ConnectArrangement, panes: SplitPanes, size: CGSize) -> some View {
        switch arrangement {
        case .drawer:
            EmptyView()

        case .sideBySide:
            ScrollView {
                connectActions(.statisticsPane)
            }
            .scrollIndicators(.hidden)
            .frame(width: panes.firstEnd)
            .background(drawerBackground.ignoresSafeArea())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(themeManager.currentTheme.borderBaseColor)
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

        case .stacked:
            VStack(spacing: 0) {
                ScrollView {
                    connectActions(.stackedPane)
                }
                .scrollIndicators(.hidden)

                // the action buttons stay at the pane's foot, under the thumb
                connectActions(.actionButtons)
                    .padding()
            }
            .frame(height: size.height - panes.secondStart)
            .background(
                drawerBackground
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .ignoresSafeArea(edges: .bottom)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    /**
     * The connect canvas and its status: in the phone layout over the whole
     * window, above the drawer; in a split, in the connect pane, with devices
     * online under the status (stacked) or the action buttons under the
     * canvas (side by side). The canvas takes the room the rest leaves.
     */
    private func canvasPane(arrangement: ConnectArrangement, drawerTop: CGFloat) -> some View {
        VStack(spacing: 0) {

            GeometryReader { slot in

                let placement = canvasPlacement(
                    arrangement: arrangement,
                    height: slot.size.height,
                    drawerTop: drawerTop
                )

                VStack(spacing: 0) {

                    Spacer(minLength: 0)

                    ConnectButtonView(
                        gridPoints:
                            connectViewModel.gridPoints,
                        gridWidth: connectViewModel.gridWidth,
                        connectionStatus: connectViewModel.connectionStatus,
                        windowCurrentSize: connectViewModel.windowCurrentSize,
                        connect: connectViewModel.connect,
                        disconnect: connectViewModel.disconnect,
                        connectTunnel: {
                            deviceManager.vpnManager?.updateVpnService()
                        },
                        contractStatus: connectViewModel.contractStatus,
                        openUpgradeSheet: {
                            connectViewModel.isPresentedUpgradeSheet = true
                        },
                        currentPlan: isPro ? .supporter : .none,
                        isPollingSubscriptionBalance: subscriptionBalanceViewModel.isPolling,
                        showProviderLocations: {
                            presentedStatsSheet = .providerLocations
                        },
                        tunnelConnected: $connectViewModel.tunnelConnected,
                        canvasSide: placement.canvasSide
                    )

                    if arrangement == .stacked {
                        ConnectPeersLine(
                            openLocations: { providerListSheetViewModel.isPresented = true },
                            fillsWidth: false
                        )
                    }

                    Spacer(minLength: 0).frame(height: placement.bottomSpacer)

                    Spacer(minLength: 0)

                }
                .frame(width: slot.size.width, height: slot.size.height)
                .onAppear {
                    
                    connectViewModel.updateGrid()
                    connectViewModel.refreshTunnelStatus()
                    
                    /**
                     * Create callback function for prompting rating
                     */
                    connectViewModel.requestReview = {
                        Task {
                            
                            if let device = deviceManager.device {
                                
                                if device.getShouldShowRatingDialog() {
                                    device.setCanShowRatingDialog(false)
                                    try await Task.sleep(for: .seconds(2))
                                    requestReview()
                                }
                                
                            }
                            
                        }
                    }
                    
                }

            }

            if arrangement == .sideBySide {
                // Disconnect at the pane's foot, under the thumb
                connectActions(.actionButtons)
                    .frame(maxWidth: TabletLayout.contentWidth)
                    .padding()
            }

        }
    }

    /// Where the canvas goes in a slot of `height`: above the drawer in the
    /// phone layout, else centered in its pane, at a size the slot holds.
    private func canvasPlacement(arrangement: ConnectArrangement, height: CGFloat, drawerTop: CGFloat) -> CanvasPlacement {
        switch arrangement {
        case .drawer:
            return SplitLayout.drawerCanvasPlacement(
                height: height,
                drawerTop: drawerTop,
                statusHeight: statusLineHeight
            )
        case .stacked, .sideBySide:
            return CanvasPlacement(
                canvasSide: SplitLayout.paneCanvasSide(
                    height: height,
                    reservedHeight: arrangement == .stacked ? SplitLayout.peersLineHeight : 0,
                    statusHeight: statusLineHeight
                ),
                bottomSpacer: 0
            )
        }
    }

    /// The location picker's width as a popover: within the pane of the row
    /// it points at, so it never crosses the fold.
    private func locationPopoverWidth(arrangement: ConnectArrangement, panes: SplitPanes, width: CGFloat) -> CGFloat {
        let paneWidth = arrangement == .sideBySide ? panes.firstEnd : width
        return min(SplitLayout.locationPopoverMaxWidth, paneWidth - 32)
    }

    /// The tint of the drawer and the panes made from it.
    private var drawerBackground: some View {
        Rectangle()
            .fill(themeManager.currentTheme.tintedBackgroundBase)
            .colorMultiply(Color(white: 0.8))
    }

    /// The drawer's content, or the part of it the split connect screen puts
    /// in a pane (ConnectActionsPart).
    private func connectActions(_ part: ConnectActionsPart) -> some View {
        ConnectActions(
            connect: connectViewModel.connect,
            disconnect: connectViewModel.disconnect,
            connectionStatus: connectViewModel.connectionStatus,
            selectedProvider: connectViewModel.selectedProvider,
            selectedProviderCount: liveSelectedProviderCount,
            setIsPresented: { present in
                providerListSheetViewModel.isPresented = present
            },
            displayReconnectTunnel: displayReconnectTunnel,
            reconnectTunnel: deviceManager.vpnManager?.updateVpnService,
            contractStatus: connectViewModel.contractStatus,
            windowCurrentSize: connectViewModel.windowCurrentSize,
            isPollingSubscriptionBalance: subscriptionBalanceViewModel.isPolling,
            availableByteCount: subscriptionBalanceViewModel.availableByteCount,
            pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
            usedByteCount: subscriptionBalanceViewModel.usedBalanceByteCount,
            promptMoreDataFlow: {
                promptMoreDataFlow()
                isSheetExpanded = false
            },
            openUpgradeSheet: {
                isSheetExpanded = false
                connectViewModel.isPresentedUpgradeSheet = true
            },
            meanReliabilityWeight: meanReliabilityWeight,
            referralLine: referralLinkViewModel.referralBonusLine,
            openReferrals: {
                isSheetExpanded = false
                isPresentedReferrals = true
            },
            openDataInfo: {
                isSheetExpanded = false
                isPresentedDataInfo = true
            },
            outOfBalanceKind: outOfBalanceKind(subscriptionBalanceViewModel.lastWidgetBalanceSnapshot),
            reservedByteCount: Int(subscriptionBalanceViewModel.lastWidgetBalanceSnapshot?.openTransferByteCount ?? 0),
            balanceRecovery: connectViewModel.balanceRecoveryState,
            cancelBalanceRecovery: connectViewModel.clearBalanceRecovery,
            isPro: isPro,
            paymentPastDue: subscriptionBalanceViewModel.paymentPastDue,
            updatePaymentMethodURL: {
                await subscriptionBalanceViewModel.updatePaymentMethodURL()
            },
            selectedWindowType: $deviceManager.selectedWindowType,
            fixedIpSize: $deviceManager.fixedIpSize,
            allowDirect: $deviceManager.allowDirect,
            postQuantumEncryption: $deviceManager.postQuantumEncryption,
            dailyBalanceByteCount: subscriptionBalanceViewModel.startBalanceByteCount,
            openStatsSheet: { sheet in
                presentedStatsSheet = sheet
            },
            part: part
        )
    }

    /**
     * The phone drawer: collapsed, the location row and the action buttons
     * over the tab bar; dragged up, everything. It runs edge to edge behind
     * the tab bar.
     */
    private func drawer(
        safeAreaBottom: CGFloat,
        screenHeight: CGFloat,
        collapsedHeight sheetCollapsedHeight: CGFloat,
        expandedHeight sheetExpandedHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {

            // Sheet header: drag handle + divider. Its measured height
            // feeds the collapsed peek, which shows header + content
            // above the fold + the standard gap over the tab bar.
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 36, height: 4)
                        .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity)

                Divider()
            }
            .background(
                GeometryReader { headerGeometry in
                    Color.clear.preference(
                        key: SheetHeaderHeightKey.self,
                        value: headerGeometry.size.height
                    )
                }
            )

            // Sheet content can scroll only when expanded
            ScrollViewReader { sheetScrollProxy in
            ScrollView {
                VStack(spacing: 0) {
                    // top marker, used to detect when the content
                    // is scrolled to the very top
                    Color.clear
                        .frame(height: 0)
                        .id("connectSheetTop")
                        .background(
                            GeometryReader { markerGeometry in
                                Color.clear.preference(
                                    key: SheetScrollTopOffsetKey.self,
                                    value: markerGeometry.frame(in: .named("connectSheetScroll")).minY
                                )
                            }
                        )
                    connectActions(.drawer)

                    // the sheet extends past the tab content area by
                    // exactly the bottom inset; matching that here
                    // leaves the last card ending at the tab bar with
                    // its own 16pt bottom padding as the standard gap
                    Spacer()
                        .frame(height: safeAreaBottom)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(!isSheetExpanded)
            .coordinateSpace(name: "connectSheetScroll")
            .onPreferenceChange(SheetScrollTopOffsetKey.self) { minY in
                if let minY = minY {
                    if sheetScrollBaseline == nil {
                        sheetScrollBaseline = minY
                    }
                    sheetScrollAtTop = (sheetScrollBaseline ?? 0) - 4 <= minY
                }
            }
            .onPreferenceChange(ConnectActionsFoldPreferenceKey.self) { maxY in
                sheetFoldMaxY = maxY
            }
            .onChange(of: isSheetExpanded) { expanded in
                // when the sheet collapses, reset the content to the top
                if !expanded {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        sheetScrollProxy.scrollTo("connectSheetTop", anchor: .top)
                    }
                }
            }
            }
        }
        .onPreferenceChange(SheetHeaderHeightKey.self) { height in
            sheetHeaderHeight = height
        }
        .frame(height: currentSheetHeight(collapsedHeight: sheetCollapsedHeight, maxHeight: sheetExpandedHeight))
        // a wide compact window (a phone in landscape) wraps the
        // drawer's content at the readable column width and centers
        // it; phones in portrait are narrower than the column
        .frame(maxWidth: TabletLayout.contentWidth)
        .background(drawerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.2), radius: 8, y: -2)
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.1))
        )
        // UIKit pan under the hood: vertical drags anywhere on the
        // sheet move it, while taps and horizontal slides pass through
        // to the controls inside. scroll views in the sheet defer to
        // the pan: while collapsed every vertical drag moves the
        // sheet; expanded, drags in the handle region always move it,
        // and drags over the content move it only when the content is
        // at its top and the drag is downward (closing)
        .verticalPanGesture(
            onChanged: { translation in
                sheetDragOnChanged(translation, collapsedHeight: sheetCollapsedHeight, maxHeight: sheetExpandedHeight)
            },
            onEnded: { translation, velocity in
                sheetDragOnEnded(translation, velocity: velocity, collapsedHeight: sheetCollapsedHeight, maxHeight: sheetExpandedHeight)
            },
            shouldBegin: { translation, location in
                if !isSheetExpanded {
                    return true
                }
                // the drag handle and divider sit above the scroll content
                if location.y < 48 {
                    return true
                }
                return sheetScrollAtTop && 0 < translation
            }
        )
        .offset(y: sheetY(screenHeight: screenHeight, collapsedHeight: sheetCollapsedHeight, maxHeight: sheetExpandedHeight))
        .ignoresSafeArea(edges: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.85, blendDuration: 0.2),
                   value: isSheetExpanded)
        .animation(.spring(response: 0.25, dampingFraction: 0.85, blendDuration: 0.1),
                   value: sheetDragTranslation)
        .zIndex(1)
    }

    /// The location picker, the same list in its sheet and in its popover.
    private var providerPicker: some View {
        NavigationStack {
            
            ProviderListSheetView(
                selectedProvider: connectViewModel.selectedProvider,
                connect: { provider in
                    connectViewModel.connect(provider)
                    providerListSheetViewModel.isPresented = false
                },
                connectBestAvailable: {
                    connectViewModel.connectBestAvailable()
                    providerListSheetViewModel.isPresented = false
                },
                isLoading: providerListStore.showLoadingPlaceholder,
                isRefreshing: providerListSheetViewModel.isRefreshing,
                providerCountries: providerListStore.providerCountries,
                providerDevices: providerListStore.providerDevices,
                providerRegions: providerListStore.providerRegions,
                providerCities: providerListStore.providerCities,
                providerBestSearchMatches: providerListStore.providerBestSearchMatches
            )
            .environmentObject(themeManager)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $providerListStore.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search providers"
            )
            .toolbar {
                
                ToolbarItem(placement: .principal) {
                    Text("Available providers")
                        .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        providerListSheetViewModel.isPresented = false
                    }) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .refreshable {
                providerListSheetViewModel.setIsRefreshing(true)
                let _ = await providerListStore.filterLocations(providerListStore.searchQuery)
                providerListSheetViewModel.setIsRefreshing(false)
            }
            .onAppear {
                Task {
                    await providerListStore.loadForPresentation {
                        connectViewModel.updateContractStatus()
                    }
                }
            }
            
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    private func updateInsufficientBalanceGuards() {
        connectViewModel.updateInsufficientBalanceGuards(
            plan: isPro ? .supporter : .none,
            isPollingSubscriptionBalance: subscriptionBalanceViewModel.isPolling
        )
    }

    private func checkTunnelStatus() {
        
        if connectViewModel.connectionStatus == .connected && !connectViewModel.tunnelConnected {
            self.displayReconnectTunnel = true
        } else {
            self.displayReconnectTunnel = false
        }
        
    }
    
    // The collapsed peek: sheet header + the content above the fold (location
    // row with the connect button) + the standard 12pt gap, plus the region
    // the sheet extends past the tab content area (behind the tab bar).
    // screenHeight extends past that area by exactly safeAreaBottom, so
    // whatever the inset reports, the fold lands 12pt above the tab bar —
    // consistent across devices (Android parity).
    private func collapsedSheetHeight(safeAreaBottom: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard let foldMaxY = sheetFoldMaxY, 0 < sheetHeaderHeight else {
            return sheetMinHeightFallback
        }
        // never taller than the expanded sheet (giant accessibility type),
        // which would invert the drag range
        return min(
            sheetHeaderHeight + foldMaxY + sheetFoldGap + safeAreaBottom,
            maxHeight
        )
    }

    private func currentSheetHeight(collapsedHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let base = isSheetExpanded ? maxHeight : collapsedHeight
        let dragged = base - sheetDragTranslation
        return max(collapsedHeight, min(maxHeight, dragged))
    }

    private func sheetY(screenHeight: CGFloat, collapsedHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let height = currentSheetHeight(collapsedHeight: collapsedHeight, maxHeight: maxHeight)
        return screenHeight - height
    }

    private func sheetDragOnChanged(_ translation: CGFloat, collapsedHeight: CGFloat, maxHeight: CGFloat) {
        let range = maxHeight - collapsedHeight
        // Allow both directions: negative when dragging up, positive when dragging down
        sheetDragTranslation = max(-range, min(range, translation))
    }

    // A release decides by speed first (a flick opens or closes the drawer
    // however short it was), then by distance. The content stays where it
    // is: a flick that opens the drawer shows the content from its top.
    private func sheetDragOnEnded(_ translation: CGFloat, velocity: CGFloat, collapsedHeight: CGFloat, maxHeight: CGFloat) {
        let range = maxHeight - collapsedHeight
        isSheetExpanded = ConnectSheetMomentum.isExpandedAfterRelease(
            isExpanded: isSheetExpanded,
            translation: translation,
            velocity: velocity,
            range: range
        )
        sheetDragTranslation = 0
    }

}

private struct SheetScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

// measured height of the sheet header (drag handle + divider)
private struct SheetHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


//#Preview {
//    ConnectView_iOS()
//}
#endif
