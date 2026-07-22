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
    
    @EnvironmentObject var connectViewModel: ConnectViewModel

    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    @ObservedObject private var providerListStore: ProviderListStore
    
    let logout: () -> Void
    let api: SdkApi
    let promptMoreDataFlow: () -> Void
    let meanReliabilityWeight: Double
    let isPro: Bool
    // incremented by the tab bar when the connect tab is re-tapped
    var collapseDrawerSignal: Int = 0
    @ObservedObject var providerListSheetViewModel: ProviderListSheetViewModel
    
    @State var displayReconnectTunnel: Bool = false

    @State private var isSheetExpanded = false
    @State private var sheetDragTranslation: CGFloat = 0
    @State private var presentedStatsSheet: ConnectStatsSheet? = nil

    // whether the expanded sheet's content is scrolled to the very top.
    // at the top, a downward drag closes the sheet instead of rubber-banding
    @State private var sheetScrollAtTop: Bool = true
    @State private var sheetScrollBaseline: CGFloat? = nil

    private let sheetMinHeight: CGFloat   // collapsed peek height
    private let sheetMaxHeight: CGFloat = 680   // expanded height

    
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
        self.providerListSheetViewModel = providerListSheetViewModel
        self.referralLinkViewModel = referralLinkViewModel
        self.providerListStore = providerStore

        self.promptMoreDataFlow = promptMoreDataFlow
        self.meanReliabilityWeight = meanReliabilityWeight


        self.isPro = isPro
        self.collapseDrawerSignal = collapseDrawerSignal
        self.sheetMinHeight = 280

        // adds clear button to search providers text field
        UITextField.appearance().clearButtonMode = .whileEditing
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            
            let screenHeight = geometry.size.height + geometry.safeAreaInsets.bottom
            
            ZStack(alignment: .top) {
                
                VStack {
                    
                    Spacer()
                    
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
                        tunnelConnected: $connectViewModel.tunnelConnected
                    )
                    
                    Spacer().frame(height: 112)
                    
                    Spacer()
                    
                }
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
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 0) {
                 
                    // Drag handle
                    VStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 36, height: 4)
                            .padding(.vertical, 16)
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

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
                            ConnectActions(
                                connect: connectViewModel.connect,
                                disconnect: connectViewModel.disconnect,
                                connectionStatus: connectViewModel.connectionStatus,
                                selectedProvider: connectViewModel.selectedProvider,
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
                                meanReliabilityWeight: meanReliabilityWeight,
                                totalReferrals: referralLinkViewModel.totalReferrals,
                                referralCode: referralLinkViewModel.referralCode,
                                isPro: isPro,
                                selectedWindowType: $deviceManager.selectedWindowType,
                                fixedIpSize: $deviceManager.fixedIpSize,
                                allowDirect: $deviceManager.allowDirect,
                                postQuantumEncryption: $deviceManager.postQuantumEncryption,
                                dailyBalanceByteCount: subscriptionBalanceViewModel.startBalanceByteCount,
                                openStatsSheet: { sheet in
                                    presentedStatsSheet = sheet
                                }
                            )

                            // bottom inset equal to the tab bar height so the
                            // last card isn't tucked under the tab bar
                            Spacer()
                                .frame(height: tabBarHeight(safeAreaBottom: geometry.safeAreaInsets.bottom))
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
                .frame(height: currentSheetHeight())
                .frame(maxWidth: .infinity)
                .background(
                    Rectangle()
                        .fill(themeManager.currentTheme.tintedBackgroundBase)
                        .colorMultiply(Color(white: 0.8))
                )
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
                    onChanged: sheetDragOnChanged,
                    onEnded: sheetDragOnEnded,
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
                .offset(y: sheetY(screenHeight: screenHeight))
                .ignoresSafeArea(edges: .bottom)
                .animation(.spring(response: 0.35, dampingFraction: 0.85, blendDuration: 0.2),
                           value: isSheetExpanded)
                .animation(.spring(response: 0.25, dampingFraction: 0.85, blendDuration: 0.1),
                           value: sheetDragTranslation)
                .zIndex(1)
                
            }
            .sheet(isPresented: $providerListSheetViewModel.isPresented) {
                
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
                        isLoading: providerListStore.providersLoading,
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
                        
                        // refetch the contract status
                        connectViewModel.updateContractStatus()
                        
                        Task {
                            let _ = await providerListStore.filterLocations(providerListStore.searchQuery)
                        }
                    }
                    
                }
                .background(themeManager.currentTheme.backgroundColor)
                
                
            }
            // statistics and dns detail sheets (store subscription isolated in the modifier)
            .modifier(ConnectStatsSheets(presentedStatsSheet: $presentedStatsSheet))
            // upgrade subscription
            .sheet(isPresented: $connectViewModel.isPresentedUpgradeSheet) {
                UpgradeSubscriptionSheet(
                    monthlyProduct: subscriptionManager.monthlySubscription,
                    yearlyProduct: subscriptionManager.yearlySubscription,
                    purchase: { product in
                        
                        Task {
                            do {
                                try await subscriptionManager.purchase(
                                    product: product,
                                    onSuccess: {
                                        subscriptionBalanceViewModel.startPolling()
                                    }
                                )
                                
                            } catch(let error) {
                                print("error making purchase: \(error)")
                            }
                            
                            
                        }
                        
                    },
                    isPurchasing: subscriptionManager.isPurchasing,
                    purchaseSuccess: subscriptionManager.purchaseSuccess,
                    purchasePending: subscriptionManager.purchasePending,
                    dismiss: {
                        connectViewModel.isPresentedUpgradeSheet = false
                        // the purchase flags describe ONE attempt; letting them
                        // survive is what showed "You're premium." to a user who
                        // had not actually completed a purchase
                        subscriptionManager.resetPurchaseState()
                    }
                )
                .environmentObject(themeManager)
            }
            
            // upgrade guest account flow
            .fullScreenCover(isPresented: $connectViewModel.isPresentedCreateAccount) {
                LoginNavigationView(
                    api: api,
                    cancel: {
                        connectViewModel.isPresentedCreateAccount = false
                    },
                    
                    handleSuccess: { jwt in
                        Task {
                            await handleSuccessWithJwt(jwt)
                            connectViewModel.isPresentedCreateAccount = false
                        }
                    }
                )
                .id(deviceManager.activeHostName)
            }
            .onChange(of: connectViewModel.connectionStatus) { _ in
                checkTunnelStatus()
            }
            .onChange(of: connectViewModel.tunnelConnected) { _ in
                checkTunnelStatus()
            }
            .onChange(of: collapseDrawerSignal) { _ in
                // the connect tab was re-tapped. close the drawer.
                isSheetExpanded = false
            }
        }

    }
    
    private func handleSuccessWithJwt(_ jwt: String) async {
        
        let result = await deviceManager.authenticateNetworkClient(jwt)
        
        if case .failure(let error) = result {
            print("[ContentView] handleSuccessWithJwt: \(error.localizedDescription)")
            
            snackbarManager.showSnackbar(message: String(localized: "There was an error creating your network. Please try again later."))
            
            return
        }
        
        // TODO: fade out login flow
        // TODO: create navigation view model and switch to main app instead of checking deviceManager.device
        
    }
    
    private func checkTunnelStatus() {
        
        if connectViewModel.connectionStatus == .connected && !connectViewModel.tunnelConnected {
            self.displayReconnectTunnel = true
        } else {
            self.displayReconnectTunnel = false
        }
        
    }
    
    private func currentSheetHeight() -> CGFloat {
        let base = isSheetExpanded ? sheetMaxHeight : sheetMinHeight
        let dragged = base - sheetDragTranslation
        return max(sheetMinHeight, min(sheetMaxHeight, dragged))
    }

    private func sheetY(screenHeight: CGFloat) -> CGFloat {
        let height = currentSheetHeight()
        return screenHeight - height
    }
    
    private func sheetDragOnChanged(_ translation: CGFloat) {
        let range = sheetMaxHeight - sheetMinHeight
        // Allow both directions: negative when dragging up, positive when dragging down
        sheetDragTranslation = max(-range, min(range, translation))
    }

    private func sheetDragOnEnded(_ translation: CGFloat) {
        let range = sheetMaxHeight - sheetMinHeight
        let threshold = range * 0.25
        if isSheetExpanded {
            if translation > threshold { isSheetExpanded = false }
        } else {
            if -translation > threshold { isSheetExpanded = true }
        }
        sheetDragTranslation = 0
    }

    // the standard tab bar content height plus the bottom safe area it covers
    private func tabBarHeight(safeAreaBottom: CGFloat) -> CGFloat {
        return 49 + safeAreaBottom
    }

}

private struct SheetScrollTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}


//#Preview {
//    ConnectView_iOS()
//}
#endif
