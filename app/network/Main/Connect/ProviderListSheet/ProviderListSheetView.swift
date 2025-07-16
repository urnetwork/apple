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
    
    var selectedProvider: SdkConnectLocation?
    var connect: (SdkConnectLocation) -> Void
    var connectBestAvailable: () -> Void
    var isLoading: Bool
    
    /**
     * Provider lists
     */
    var providerCountries: [SdkConnectLocation]
    var providerPromoted: [SdkConnectLocation]
    var providerDevices: [SdkConnectLocation]
    var providerRegions: [SdkConnectLocation]
    var providerCities: [SdkConnectLocation]
    var providerBestSearchMatches: [SdkConnectLocation]
    
    /**
     * Close sheet
     */
    
    var body: some View {
        
        if isLoading {
            
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
            providerCountries: providerCountries,
            providerPromoted: [],
            providerDevices: [],
            providerRegions: [],
            providerCities: providerCities,
            providerBestSearchMatches: []
//            setIsPresented: {_ in },
//            searchText: .constant("")
        )
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
    
}
