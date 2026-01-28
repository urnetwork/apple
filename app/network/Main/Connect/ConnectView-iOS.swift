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
    @ObservedObject var providerListSheetViewModel: ProviderListSheetViewModel
    
    @State var displayReconnectTunnel: Bool = false
    
    @State private var isSheetExpanded = false
    @GestureState private var sheetDragTranslation: CGFloat = 0

    private let sheetMinHeight: CGFloat   // collapsed peek height
    private let sheetMaxHeight: CGFloat = 640   // expanded height

    
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
        isPro: Bool
    ) {
        self.logout = logout
        self.api = api
        self.providerListSheetViewModel = providerListSheetViewModel
        self.referralLinkViewModel = referralLinkViewModel
        self.providerListStore = providerStore
        
        self.promptMoreDataFlow = promptMoreDataFlow
        self.meanReliabilityWeight = meanReliabilityWeight
        

        self.isPro = isPro
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
                .onChange(of: connectViewModel.connectionStatus) { newValue in
                    
                    // Cancel any existing banner task
                    connectViewModel.upgradeBannerTask?.cancel()
                    connectViewModel.upgradeBannerTask = nil
                    
                    if newValue == .connected && !connectViewModel.showUpgradeBanner && !isPro {
                        // Show the banner after 10 seconds when connected
                        connectViewModel.upgradeBannerTask = Task {
                            try? await Task.sleep(for: .seconds(10))
                            // Check if the task was not cancelled before showing the banner
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                withAnimation {
                                    connectViewModel.showUpgradeBanner = true
                                }
                            }
                        }
                    } else if newValue != .connected {
                        // Hide the banner when disconnected
                        withAnimation {
                            connectViewModel.showUpgradeBanner = false
                        }
                    }
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
                    .contentShape(Rectangle())
                    .gesture(sheetDragGesture())

                    Divider()

                    // Sheet content can scroll only when expanded
                    ScrollView {
                        VStack(spacing: 0) {
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
                                isPro: isPro,
                                selectedWindowType: $deviceManager.selectedWindowType,
                                fixedIpSize: $deviceManager.fixedIpSize,
                                dailyBalanceByteCount: subscriptionBalanceViewModel.startBalanceByteCount
                            )
                        }
                    }
                    .scrollIndicators(.hidden)
//                    .scrollDisabled(!isSheetExpanded) // we can set this once sheet takes up entire view
                    .scrollDisabled(true)
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
                    dismiss: {
                        connectViewModel.isPresentedUpgradeSheet = false
                    }
                )
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
            }
            .onChange(of: connectViewModel.connectionStatus) { _ in
                checkTunnelStatus()
            }
            .onChange(of: connectViewModel.tunnelConnected) { _ in
                checkTunnelStatus()
            }
        }
        
    }
    
    private func handleSuccessWithJwt(_ jwt: String) async {
        
        let result = await deviceManager.authenticateNetworkClient(jwt)
        
        if case .failure(let error) = result {
            print("[ContentView] handleSuccessWithJwt: \(error.localizedDescription)")
            
            snackbarManager.showSnackbar(message: "There was an error creating your network. Please try again later.")
            
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
    
    private func sheetDragGesture() -> some Gesture {
        let range = sheetMaxHeight - sheetMinHeight
        return DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($sheetDragTranslation) { value, state, _ in
                // Allow both directions: negative when dragging up, positive when dragging down
                let delta = value.translation.height
                state = max(-range, min(range, delta))
            }
            .onEnded { value in
                let delta = value.translation.height
                let threshold = range * 0.25
                if isSheetExpanded {
                    if delta > threshold { isSheetExpanded = false }
                } else {
                    if -delta > threshold { isSheetExpanded = true }
                }
            }
    }

}


//#Preview {
//    ConnectView_iOS()
//}
#endif
