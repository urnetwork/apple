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
    
    @StateObject private var providerListStore: ProviderListStore
    
    var logout: () -> Void
    var api: SdkApi
    @ObservedObject var providerListSheetViewModel: ProviderListSheetViewModel
    
    init(
        api: SdkApi,
        logout: @escaping () -> Void,
        device: SdkDeviceRemote?,
        providerListSheetViewModel: ProviderListSheetViewModel,
        referralLinkViewModel: ReferralLinkViewModel
    ) {
        self.logout = logout
        self.api = api
        self.providerListSheetViewModel = providerListSheetViewModel
        self.referralLinkViewModel = referralLinkViewModel
        
        _providerListStore = StateObject(wrappedValue: ProviderListStore(api: api))
        
        // adds clear button to search providers text field
        UITextField.appearance().clearButtonMode = .whileEditing
    }
    
    var body: some View {
        
        // let isGuest = deviceManager.parsedJwt?.guestMode ?? true
        
        VStack {
            
            HStack {
                            
                if subscriptionBalanceViewModel.currentPlan != .supporter {
                    Text("Need more data, faster?")
                        .font(themeManager.currentTheme.bodyFont)
                    
                    Spacer()
                    
                    Button(action: {
                        connectViewModel.isPresentedUpgradeSheet = true
                    }) {
                     
                        Text("Upgrade Now")
                            .font(themeManager.currentTheme.bodyFont)
                            .fontWeight(.bold)
                        
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.accent, lineWidth: 1)
                    )
                }
                
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(subscriptionBalanceViewModel.currentPlan != .supporter ? .urElectricBlue : .clear)
            .opacity(connectViewModel.showUpgradeBanner ? 1 : 0)
            .animation(.easeInOut(duration: 0.5), value: connectViewModel.showUpgradeBanner)
            .onChange(of: connectViewModel.connectionStatus) { newValue in
                if newValue == .connected && !connectViewModel.showUpgradeBanner && subscriptionBalanceViewModel.currentPlan != .supporter {
                    // Show the banner after 10 seconds when connected
                    Task {
                        try? await Task.sleep(for: .seconds(10))
                        withAnimation {
                            connectViewModel.showUpgradeBanner = true
                        }
                    }
                } else if newValue != .connected {
                    // Hide the banner when disconnected
                    withAnimation {
                        connectViewModel.showUpgradeBanner = false
                    }
                }
            }
            
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
                currentPlan: subscriptionBalanceViewModel.currentPlan,
                isPollingSubscriptionBalance: subscriptionBalanceViewModel.isPolling,
                tunnelConnected: $connectViewModel.tunnelConnected
            )
            
            Spacer()
            
            Button(action: {
                providerListSheetViewModel.isPresented = true
            }) {
                
                SelectedProvider(
                    selectedProvider: connectViewModel.selectedProvider,
                    getProviderColor: connectViewModel.getProviderColor
                )
                
            }
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .clipShape(.capsule)
            
            Spacer().frame(height: 16)
            
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
        // .padding()
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    let _ = await providerListStore.filterLocations(providerListStore.searchQuery)
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
    
}

//#Preview {
//    ConnectView_iOS()
//}
#endif
