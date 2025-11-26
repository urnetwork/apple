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
    
    let groupName: String
    let providers: [SdkConnectLocation]
    let selectedProvider: SdkConnectLocation?
    let connect: (SdkConnectLocation) -> Void
    let connectBestAvailable: () -> Void = {}
    
    #if os(iOS)
    let padding: CGFloat = 16
    #elseif os(macOS)
    let padding: CGFloat = 0
    #endif
    
    var body: some View {
        
        Section(
            header: HStack {
                Text(groupName)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                Spacer()
            }
                .padding(.horizontal, padding)
                .padding(.vertical, 8)
        ) {
            
            ForEach(providers, id: \.connectLocationId) { provider in
                ProviderListItemView(
                    name: provider.name,
                    providerCount: provider.providerCount,
                    color: getProviderColor(provider),
                    isSelected: selectedProvider != nil && selectedProvider?.connectLocationId?.cmp(provider.connectLocationId) == 0,
                    connect: {
                        connect(provider)
                    },
                    isStable: provider.stable,
                    isStrongPrivacy: provider.strongPrivacy
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listRowBackground(Color.clear)
        
    }
    
}

