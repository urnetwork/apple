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
    @Environment(\.requestReview) private var requestReview
    
    @EnvironmentObject var connectViewModel: ConnectViewModel
    
    @State var isLoading: Bool = false
    
    @State private var isProviderTableVisible: Bool = false
    
    var body: some View {
         
        VStack {
            
            HStack(spacing: 0) {
             
                VStack {
                    
                    ConnectButtonView(
                        gridPoints:
                            connectViewModel.gridPoints,
                        gridWidth: connectViewModel.gridWidth,
                        connectionStatus: connectViewModel.connectionStatus,
                        windowCurrentSize: connectViewModel.windowCurrentSize,
                        connect: connectViewModel.connect,
                        disconnect: connectViewModel.disconnect
                    )
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
                    .transition(.move(edge: .trailing))
                }
                
            }
            .frame(maxWidth: .infinity)
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
        
        VStack {
            
            List {
                
                if (isLoading) {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(32)
                } else {
                
                    ProviderListGroup(
                        groupName: "Best Search Matches",
                        providers: providerBestSearchMatches,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                    ProviderListGroup(
                        groupName: "Promoted Locations",
                        providers: providerPromoted,
                        selectedProvider: selectedProvider,
                        connect: connect,
                        connectBestAvailable: connectBestAvailable,
                        isPromotedLocations: true
                    )
                    ProviderListGroup(
                        groupName: "Countries",
                        providers: providerCountries,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                    ProviderListGroup(
                        groupName: "Regions",
                        providers: providerRegions,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                    ProviderListGroup(
                        groupName: "Cities",
                        providers: providerCities,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                    ProviderListGroup(
                        groupName: "Devices",
                        providers: providerDevices,
                        selectedProvider: selectedProvider,
                        connect: connect
                    )
                    
                }
                
            }
            .searchable(
                text: $searchQuery,
                prompt: "Search providers"
            )
            .frame(maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            
        }
        .frame(maxWidth: 260)
        
    }
}

//#Preview {
//    ConnectView_macOS()
//}
#endif
