//
//  ConnectView-macOS.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/11.
//

import SwiftUI
import URnetworkSdk

#if os(macOS)
struct ConnectView_macOS: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @Environment(\.requestReview) private var requestReview
    
    @EnvironmentObject var connectViewModel: ConnectViewModel
    
    @State var isLoading: Bool = false
    
    @State private var isProviderTableVisible: Bool = false
    
    var body: some View {
         
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
            
            
            HStack(spacing: 0) {
             
                VStack {
                    
                    ConnectButtonView(
                        gridPoints:
                            connectViewModel.gridPoints,
                        gridWidth: connectViewModel.gridWidth,
                        connectionStatus: connectViewModel.connectionStatus,
                        windowCurrentSize: connectViewModel.windowCurrentSize,
                        connect: {
                            connectViewModel.connect()
                            withAnimation(.spring(duration: 0.3)) {
                                isProviderTableVisible = false
                            }
                        },
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
                    .animation(.spring(duration: 0.3), value: isProviderTableVisible)
                    .frame(maxHeight: .infinity)
                    
                    HStack {
                        
                        Button(
                            action: {
                                withAnimation(.spring(duration: 0.3)) {
                                    self.isProviderTableVisible.toggle()
                                }
                            }
                        ) {
                            SelectedProvider(
                                selectedProvider: connectViewModel.selectedProvider,
                                getProviderColor: connectViewModel.getProviderColor
                            )
                        }
                        .buttonStyle(.plain)
                        
                    }
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .clipShape(.capsule)
                    
                    Spacer().frame(height: 32)
                    
                }
                .frame(maxWidth: .infinity)
                
                Divider()
                
                if isProviderTableVisible {
                    ProviderTable(
                        selectedProvider: connectViewModel.selectedProvider,
                        connect: { provider in
                            connectViewModel.connect(provider)
                        },
                        connectBestAvailable: {
                            connectViewModel.connectBestAvailable()
                        },
                        providerCountries: connectViewModel.providerCountries,
                        providerPromoted: connectViewModel.providerPromoted,
                        providerDevices: connectViewModel.providerDevices,
                        providerRegions: connectViewModel.providerRegions,
                        providerCities: connectViewModel.providerCities,
                        providerBestSearchMatches: connectViewModel.providerBestSearchMatches,
                        searchQuery: $connectViewModel.searchQuery,
                        refresh: {
                            Task {
                                let _ = await connectViewModel.filterLocations(connectViewModel.searchQuery)
                            }
                        },
                        isLoading: connectViewModel.providersLoading
                    )
                    .frame(maxWidth: 260)
                    .frame(maxHeight: .infinity)
                    .searchable(
                        text: $connectViewModel.searchQuery,
                        prompt: "Search providers"
                    )
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button(action: {
                                Task {
                                    let _ = await connectViewModel.filterLocations(connectViewModel.searchQuery)
                                }
                            }) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(isLoading)
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )

                }
                
            }
            .animation(.spring(duration: 0.3), value: isProviderTableVisible)
            .frame(maxWidth: .infinity)
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
                                    
                                    withAnimation {
                                        subscriptionManager.setPurchaseSuccess(true)
                                    }
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
        
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    withAnimation(.spring(duration: 0.3)) {
                        isProviderTableVisible.toggle()
                    }
                }) {
                    Image("ur.symbols.tab.connect")
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .help(isProviderTableVisible ? "Hide Provider List" : "Show Provider List")
                }
                .background(
                    isProviderTableVisible ?
                    themeManager.currentTheme.textFaintColor :
                        Color.clear
                )
                .cornerRadius(4)
            }
        }
        
    }
}

struct ProviderTable: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    var selectedProvider: SdkConnectLocation?
    var connect: (SdkConnectLocation) -> Void
    var connectBestAvailable: () -> Void
    
    /**
     * Provider lists
     */
    var providerCountries: [SdkConnectLocation]
    var providerPromoted: [SdkConnectLocation]
    var providerDevices: [SdkConnectLocation]
    var providerRegions: [SdkConnectLocation]
    var providerCities: [SdkConnectLocation]
    var providerBestSearchMatches: [SdkConnectLocation]
    
    @Binding var searchQuery: String
    
    var refresh: () -> Void
    var isLoading: Bool
    
    var body: some View {
            
        List {
            
            if (isLoading) {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(32)
            } else {
            
                if !providerBestSearchMatches.isEmpty {
                    ProviderListGroup(
                        groupName: "Best Search Matches",
                        providers: providerBestSearchMatches,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                }

                if !providerPromoted.isEmpty {
                    ProviderListGroup(
                        groupName: "Promoted Locations",
                        providers: providerPromoted,
                        selectedProvider: selectedProvider,
                        connect: connect,
                        connectBestAvailable: connectBestAvailable,
                        isPromotedLocations: true
                    )
                }

                if !providerCountries.isEmpty {
                    ProviderListGroup(
                        groupName: "Countries",
                        providers: providerCountries,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                }
                
                if !providerRegions.isEmpty {
                    ProviderListGroup(
                        groupName: "Regions",
                        providers: providerRegions,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                }

                if !providerCities.isEmpty {
                    ProviderListGroup(
                        groupName: "Cities",
                        providers: providerCities,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                }

                if !providerDevices.isEmpty {
                    ProviderListGroup(
                        groupName: "Devices",
                        providers: providerDevices,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                }
                
            }
            
        }
        
    }
}

//#Preview {
//    ConnectView_macOS()
//}
#endif
