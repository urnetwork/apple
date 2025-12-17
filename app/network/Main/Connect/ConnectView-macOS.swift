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

        @ObservedObject private var providerListStore: ProviderListStore
        
        @State var displayReconnectTunnel: Bool = false
        
        let promptMoreDataFlow: () -> Void
        let meanReliabilityWeight: Double
        let totalReferrals: Int
        let isPro: Bool

        init(
            urApiService: UrApiServiceProtocol,
            providerStore: ProviderListStore,
            promptMoreDataFlow: @escaping () -> Void,
            meanReliabilityWeight: Double,
            totalReferrals: Int,
            isPro: Bool
        ) {
            self.providerListStore = providerStore
            self.promptMoreDataFlow = promptMoreDataFlow
            self.meanReliabilityWeight = meanReliabilityWeight
            self.totalReferrals = totalReferrals
            self.isPro = isPro
        }

        var body: some View {

            ScrollView {

                HStack(spacing: 0) {

                    VStack {

                        ConnectButtonView(
                            gridPoints: connectViewModel.gridPoints,
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
                            tunnelConnected: $connectViewModel.tunnelConnected,
                        )
                        .animation(.spring(duration: 0.3), value: isProviderTableVisible)
                        .frame(maxHeight: .infinity)
                        
                        Spacer().frame(height: 24)
                        
                        ConnectActions(
                            connect: connectViewModel.connect,
                            disconnect: connectViewModel.disconnect,
                            connectionStatus: connectViewModel.connectionStatus,
                            selectedProvider: connectViewModel.selectedProvider,
                            setIsPresented: { present in
                                isProviderTableVisible = true
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
                                connectViewModel.isPresentedUpgradeSheet = true
                            },
                            meanReliabilityWeight: meanReliabilityWeight,
                            totalReferrals: totalReferrals,
                            isPro: isPro
                        )
                        .frame(maxWidth: 600)

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
                            providerCountries: providerListStore.providerCountries,
                            providerDevices: providerListStore.providerDevices,
                            providerRegions: providerListStore.providerRegions,
                            providerCities: providerListStore.providerCities,
                            providerBestSearchMatches: providerListStore.providerBestSearchMatches,
                            searchQuery: $providerListStore.searchQuery,
                            refresh: {
                                Task {
                                    let _ = await providerListStore.filterLocations(
                                        providerListStore.searchQuery)
                                }
                            },
                            isLoading: providerListStore.providersLoading
                        )
                        .frame(maxWidth: 260)
                        .frame(maxHeight: .infinity)
                        .searchable(
                            text: $providerListStore.searchQuery,
                            prompt: "Search providers"
                        )
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
                                Button(action: {
                                    Task {
                                        let _ = await providerListStore.filterLocations(
                                            providerListStore.searchQuery)
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
            .onChange(of: connectViewModel.connectionStatus) { _ in
                checkTunnelStatus()
            }
            .onChange(of: connectViewModel.tunnelConnected) { _ in
                checkTunnelStatus()
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
            }

            // upgrade subscription
            .sheet(isPresented: $connectViewModel.isPresentedUpgradeSheet) {
                UpgradeSubscriptionSheet(
                    monthlyProduct: subscriptionManager.monthlySubscription,
                    yearlyProduct: subscriptionManager.yearlySubscription,
                    purchase: { product in

                        let initiallyConnected = deviceManager.device?.getConnected() ?? false

                        if initiallyConnected {
                            connectViewModel.disconnect()
                        }

                        Task {
                            do {
                                try await subscriptionManager.purchase(
                                    product: product,
                                    onSuccess: {
                                        subscriptionBalanceViewModel.startPolling()
                                    }
                                )

                            } catch (let error) {
                                print("error making purchase: \(error)")
                            }

                            if initiallyConnected {
                                connectViewModel.connect()
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
                            .help(
                                isProviderTableVisible ? "Hide Provider List" : "Show Provider List"
                            )
                    }
                    .background(
                        isProviderTableVisible
                            ? themeManager.currentTheme.textFaintColor : Color.clear
                    )
                    .cornerRadius(4)
                }
            }
        }
        
        private func checkTunnelStatus() {
            
            if connectViewModel.connectionStatus == .connected && !connectViewModel.tunnelConnected {
                self.displayReconnectTunnel = true
            } else {
                self.displayReconnectTunnel = false
            }
            
        }
        
    }

    struct ProviderTable: View {

        @EnvironmentObject var themeManager: ThemeManager
        let selectedProvider: SdkConnectLocation?
        let connect: (SdkConnectLocation) -> Void
        let connectBestAvailable: () -> Void

        /**
         * Provider lists
         */
        let providerCountries: [SdkConnectLocation]
        let providerDevices: [SdkConnectLocation]
        let providerRegions: [SdkConnectLocation]
        let providerCities: [SdkConnectLocation]
        let providerBestSearchMatches: [SdkConnectLocation]

        @Binding var searchQuery: String

        let refresh: () -> Void
        let isLoading: Bool
        let padding: CGFloat = 0

        var body: some View {

            List {

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(32)
                } else {
                    
                    /**
                     * nothing is being searched, or results are empty
                     * show "best available provider"
                     */
                    if providerBestSearchMatches.isEmpty {
                        /**
                         * best available provider
                         */
                        Section(
                            header: HStack {
                                Text("Promoted Locations")
                                    .font(themeManager.currentTheme.bodyFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                                Spacer()
                            }
                                .padding(.horizontal, padding)
                                .padding(.vertical, 8)
                        ) {
                            
                            ProviderListItemView(
                                name: "Best available provider",
                                providerCount: nil,
                                color: Color.urCoral,
                                isSelected: false,
                                connect: {
                                    connectBestAvailable()
                                },
                                isStable: true,
                                isStrongPrivacy: false
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        }
                        
                    }

                    if !providerBestSearchMatches.isEmpty {
                        ProviderListGroup(
                            groupName: "Best Search Matches",
                            providers: providerBestSearchMatches,
                            selectedProvider: selectedProvider,
                            connect: connect
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
