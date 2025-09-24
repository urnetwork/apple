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
    
    var logout: () -> Void
    var api: SdkApi
    @ObservedObject var providerListSheetViewModel: ProviderListSheetViewModel
    
    @State var displayReconnectTunnel: Bool = false
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        logout: @escaping () -> Void,
        device: SdkDeviceRemote?,
        providerListSheetViewModel: ProviderListSheetViewModel,
        referralLinkViewModel: ReferralLinkViewModel,
        providerStore: ProviderListStore
    ) {
        self.logout = logout
        self.api = api
        self.providerListSheetViewModel = providerListSheetViewModel
        self.referralLinkViewModel = referralLinkViewModel
        self.providerListStore = providerStore
        
        // _providerListStore = StateObject(wrappedValue: ProviderListStore(urApiService: urApiService))
        
        // adds clear button to search providers text field
        UITextField.appearance().clearButtonMode = .whileEditing
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            
            ZStack(alignment: .top) {
                
                VStack {
                    
                    //            if connectViewModel.showUpgradeBanner && subscriptionBalanceViewModel.currentPlan != .supporter {
                    //                HStack {
                    //                    Text("Need more data, faster?")
                    //                        .font(themeManager.currentTheme.bodyFont)
                    //
                    //                    Spacer()
                    //
                    //                    Button(action: {
                    //                        connectViewModel.isPresentedUpgradeSheet = true
                    //                    }) {
                    //                        Text("Upgrade Now")
                    //                            .font(themeManager.currentTheme.bodyFont)
                    //                            .fontWeight(.bold)
                    //                    }
                    //                    .padding(.horizontal, 12)
                    //                    .padding(.vertical, 4)
                    //                    .overlay(
                    //                        RoundedRectangle(cornerRadius: 4)
                    //                            .stroke(.accent, lineWidth: 1)
                    //                    )
                    //                }
                    //                .padding()
                    //                .frame(maxWidth: .infinity)
                    //                .background(.urElectricBlue)
                    //                .transition(.move(edge: .top).combined(with: .opacity))
                    //                .animation(.easeInOut(duration: 0.5), value: connectViewModel.showUpgradeBanner)
                    //            }
                    
                    // Spacer()
                    
                    Spacer().frame(height: 32)
                    
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
                        currentPlan: subscriptionBalanceViewModel.currentPlan,
                        isPollingSubscriptionBalance: subscriptionBalanceViewModel.isPolling,
                        tunnelConnected: $connectViewModel.tunnelConnected
                    )
                    
                    Spacer()
                    
                    //                Button(action: {
                    //                    providerListSheetViewModel.isPresented = true
                    //                }) {
                    //
                    //                    SelectedProvider(
                    //                        selectedProvider: connectViewModel.selectedProvider,
                    //                    )
                    //
                    //                }
                    //                .background(themeManager.currentTheme.tintedBackgroundBase)
                    //                .clipShape(.capsule)
                    //
                    //                Spacer().frame(height: 16)
                    
                }
                .onChange(of: connectViewModel.connectionStatus) { newValue in
                    
                    // Cancel any existing banner task
                    connectViewModel.upgradeBannerTask?.cancel()
                    connectViewModel.upgradeBannerTask = nil
                    
                    if newValue == .connected && !connectViewModel.showUpgradeBanner && subscriptionBalanceViewModel.currentPlan != .supporter {
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
                
                
                VStack {
                    Spacer()
                    
                    Rectangle()
                        .fill(themeManager.currentTheme.tintedBackgroundBase)
                        .colorMultiply(Color(white: 0.8))
                        .frame(height: 100) // Fixed height for bounce area
                        .ignoresSafeArea()
                }
                .ignoresSafeArea()
                
                
                
                ScrollView {
                    
                    Color.clear
                        .frame(height: geometry.size.height - 184)
                    
//                    GeometryReader { scrollGeometry in
//                        
////                        VStack(spacing: 0) {
//                        
//                        Rectangle()
//                            .fill(themeManager.currentTheme.tintedBackgroundBase)
//                            .colorMultiply(Color(white: 0.8))
//                            .frame(height: max(0, geometry.size.height - scrollGeometry.size.height))
                            
                    ConnectContent(
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
                        currentPlan: subscriptionBalanceViewModel.currentPlan,
                        isPollingSubscriptionBalance: subscriptionBalanceViewModel.isPolling,
                        availableByteCount: subscriptionBalanceViewModel.availableByteCount,
                        pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
                        usedByteCount: subscriptionBalanceViewModel.usedBalanceByteCount
                    )
//                    .padding(.horizontal)
                    
//                    Rectangle()
//                        .fill(themeManager.currentTheme.tintedBackgroundBase)
//                        .colorMultiply(Color(white: 0.8))
//                        .frame(height: 200) // Fixed height for bounce area
                        

//                        }
//                    }
                    
                }
                .scrollIndicators(.hidden)

                
                
                //                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                    .defaultScrollAnchor(.bottom)
                //                .offset(y: 100)
                
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
                        providerPromoted: providerListStore.providerPromoted,
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
                    subscriptionProduct: subscriptionManager.products.first,
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
    
}

struct ConnectContent: View {
    
    let connect: () -> Void
    let disconnect: () -> Void
    let connectionStatus: ConnectionStatus?
    let selectedProvider: SdkConnectLocation?
    let setIsPresented: (Bool) -> Void
    let displayReconnectTunnel: Bool
    let reconnectTunnel: (() -> Void)?
    let contractStatus: SdkContractStatus?
    let windowCurrentSize: Int32
    let currentPlan: Plan
    let isPollingSubscriptionBalance: Bool
    let availableByteCount: Int
    let pendingByteCount: Int
    let usedByteCount: Int
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
            
            VStack {
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 4)
                    .padding(.top, 8)
                
                Spacer().frame(height: 16)
                
                VStack {
                    
//                    HStack {
//                     
//                        ConnectStatusIndicator(
//                            connectionStatus: connectionStatus,
//                            displayReconnectTunnel: displayReconnectTunnel,
//                            contractStatus: contractStatus,
//                            windowCurrentSize: windowCurrentSize,
//                            isPollingSubscriptionBalance: isPollingSubscriptionBalance,
//                            currentPlan: currentPlan
//                        )
//                        
//                        Spacer()
//                        
//                    }
                    
                    /**
                     * Upgrade and participate flows
                     */
                    if (currentPlan != .supporter) {
                        
                        VStack {
                            
                            UrButton(text: "Upgrade plan", action: {})
                            
                            HStack {
                                Text("Get unlimited access to the full network and features on all platforms.")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            }
                        }
                        .padding()
                        .background(
                            themeManager.currentTheme.tintedBackgroundBase,
                        )
                        .cornerRadius(12)
                        
                        Spacer().frame(height: 16)
                        
                        VStack {
                            
                            HStack {
                                Text("Data usage")
                                    .font(themeManager.currentTheme.toolbarTitleFont)
                                
                                Spacer()
                            }
                            
                            UsageBar(
                                availableByteCount: availableByteCount,
                                pendingByteCount: pendingByteCount,
                                usedByteCount: usedByteCount
                            )
                            
                            Spacer().frame(height: 24)
                            
                            HStack {
                                Text("Need more data?")
                                Spacer()
                            }
                            
//                            UrButton(text: "Upgrade plan", action: {})
//                            
//                            Spacer().frame(height: 12)
//                            
//                            Text("or")
//                            
//                            Spacer().frame(height: 12)
                            
                            UrButton(text: "Participate", action: {})
                            
                        }
                        .padding()
                        .background(
                            themeManager.currentTheme.tintedBackgroundBase,
                        )
                        .cornerRadius(12)
                        
                        Spacer().frame(height: 16)
                    }
                    
                 
                    /**
                     * Connect button
                     */
                    VStack {
                     
                        HStack {
                        
                            Button(action: {
                                setIsPresented(true)
                            }) {
                                
                                SelectedProvider(
                                    selectedProvider: selectedProvider,
                                    openSelectProvider: {setIsPresented(true)}
                                )
                                
                            }
                            
                            Spacer()
                        }
                        
                        // todo - handle insufficient balance
                        
                        //                if (contractStatus?.insufficientBalance == true && currentPlan != .supporter && !isPollingSubscriptionBalance) {
                        //
                        //                    UrButton(
                        //                        text: "Subscribe to fix",
                        //                        action: {
                        //                            openUpgradeSheet()
                        //                            // connectTunnel()
                        //                        },
                        //                        style: .outlineSecondary
                        //                    )
                        //
                        //                }
                        
                        
                        if (connectionStatus == .disconnected) {
                            HStack {
                                UrButton(text: "Connect", action: connect)
                            }
                        }
                        
                        if (connectionStatus != .disconnected && !displayReconnectTunnel) {
                            UrButton(text: "Disconnect", action: disconnect)
                        }
                        
                        if displayReconnectTunnel {
                            UrButton(
                                text: "Reconnect",
                                action: reconnectTunnel ?? {},
                            )
                        }
                        
    //                        .frame(maxWidth: .infinity)
                        
                    }
                    .padding()
                    .background(
                        themeManager.currentTheme.tintedBackgroundBase,
                    )
                    .cornerRadius(12)
    //                    .border(Color(.secondarySystemBackground), width: 1)
                    
//                    Spacer().frame(height: 16)
                    
                }
                
                Spacer().frame(height: 16)
                
//                ForEach(0..<100) { _ in
//                    HStack {
//                        Text("Hello world")
//                    }
//                    .frame(maxWidth: .infinity)
//                }
            }
            
            .padding(.horizontal)
            .padding(.bottom)
//                .background(.ultraThinMaterial)
//                 .background(themeManager.currentTheme.tintedBackgroundBase.opacity(0.75))
            .background(
                Rectangle()
                    .fill(themeManager.currentTheme.tintedBackgroundBase)
                    .colorMultiply(Color(white: 0.8))
//                        .brightness(-0.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
//            .overlay(
//                Rectangle()
//                    .fill(Color.black.opacity(0.1))
//                    .frame(height: 8)
//                    .blur(radius: 6)
//                    .offset(y: -4),
//                alignment: .top
//            )
        
//            .shadow(radius: 10, y: -2)
//            .frame(maxWidth: .infinity, maxHeight: .infinity)
//            .offset(y: 200)
//            .padding(.bottom, 100)
    }
    
}

//#Preview {
//    ConnectView_iOS()
//}
#endif
