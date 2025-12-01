//
//  ProviderListSheetView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

// for iOS
struct ProviderListSheetView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let selectedProvider: SdkConnectLocation?
    let connect: (SdkConnectLocation) -> Void
    let connectBestAvailable: () -> Void
    let isLoading: Bool
    let isRefreshing: Bool
    
    /**
     * Provider lists
     */
    let providerCountries: [SdkConnectLocation]
    let providerDevices: [SdkConnectLocation]
    let providerRegions: [SdkConnectLocation]
    let providerCities: [SdkConnectLocation]
    let providerBestSearchMatches: [SdkConnectLocation]
    
    #if os(iOS)
    let padding: CGFloat = 16
    #elseif os(macOS)
    let padding: CGFloat = 0
    #endif
    
    var body: some View {
        
        if isLoading && !isRefreshing {
            
            VStack(alignment: .center) {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.backgroundColor)
            
        } else {
            
            List {
                
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
                            isStrongPrivacy: false,
                            displayIcons: false
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
            .listStyle(.plain)
            .background(themeManager.currentTheme.backgroundColor)
        }
    }
    
}

#Preview {
    
    let themeManager = ThemeManager.shared
    
    var providerCountries: [SdkConnectLocation] = [
        {
            let p = SdkConnectLocation()
            p.name = "United States"
            p.providerCount = 73
            p.countryCode = "US"
            p.locationType = SdkLocationTypeCountry
            p.connectLocationId = SdkConnectLocationId()
            return p
        }(),
        {
            let p = SdkConnectLocation()
            p.name = "Mexico"
            p.providerCount = 45
            p.countryCode = "MX"
            p.locationType = SdkLocationTypeCountry
            p.connectLocationId = SdkConnectLocationId()
            return p
        }(),
        {
            let p = SdkConnectLocation()
            p.name = "Canada"
            p.providerCount = 23
            p.countryCode = "CA"
            p.locationType = SdkLocationTypeCountry
            p.connectLocationId = SdkConnectLocationId()
            return p
        }()
    ]
    
    var providerCities: [SdkConnectLocation] = [
        {
            let p = SdkConnectLocation()
            p.name = "New York City"
            p.providerCount = 25
            p.countryCode = "US"
            p.connectLocationId = SdkConnectLocationId()
            return p
        }(),
        {
            let p = SdkConnectLocation()
            p.name = "San Francisco"
            p.providerCount = 76
            p.countryCode = "US"
            p.connectLocationId = SdkConnectLocationId()
            return p
        }(),
        {
            let p = SdkConnectLocation()
            p.name = "Chicago"
            p.providerCount = 12
            p.countryCode = "US"
            p.connectLocationId = SdkConnectLocationId()
            return p
        }()
    ]
    
    VStack {
        ProviderListSheetView(
            selectedProvider: nil,
            connect: {_ in },
            connectBestAvailable: {},
            isLoading: false,
            isRefreshing: false,
            providerCountries: providerCountries,
            providerDevices: [],
            providerRegions: [],
            providerCities: providerCities,
            providerBestSearchMatches: []
        )
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
    
}
