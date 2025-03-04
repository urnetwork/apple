//
//  ProviderListGroup.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/26.
//

import SwiftUI
import URnetworkSdk

struct ProviderListGroup: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var groupName: String
    var providers: [SdkConnectLocation]
    var selectedProvider: SdkConnectLocation?
    var connect: (SdkConnectLocation) -> Void
    var connectBestAvailable: () -> Void = {}
    var isPromotedLocations: Bool = false
    
    #if os(iOS)
    let padding: CGFloat = 16
    #elseif os(macOS)
    let padding: CGFloat = 0
    #endif
    
    var body: some View {
        
        Section(
            header: HStack {
                Text(groupName)
                    .textCase(nil) // for some reason, header text is all caps by default in swiftui
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                Spacer()
            }
                .padding(.horizontal, padding)
                .padding(.vertical, 8)
        ) {
            
            if isPromotedLocations {
                ProviderListItemView(
                    name: "Best available provider",
                    providerCount: nil,
                    color: Color.urCoral,
                    isSelected: false,
                    connect: {
                        connectBestAvailable()
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            
            ForEach(providers, id: \.connectLocationId) { provider in
                ProviderListItemView(
                    name: provider.name,
                    providerCount: provider.providerCount,
                    color: getProviderColor(provider),
                    isSelected: selectedProvider != nil && selectedProvider?.connectLocationId?.cmp(provider.connectLocationId) == 0,
                    connect: {
                        connect(provider)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listRowBackground(Color.clear)
        
    }
    
}

