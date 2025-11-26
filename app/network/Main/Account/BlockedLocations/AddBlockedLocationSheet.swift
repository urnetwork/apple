//
//  AddBlockedLocationSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 8/5/25.
//

import SwiftUI
import URnetworkSdk

struct AddBlockedLocationSheet: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    var providerCountries: [SdkConnectLocation]
    var onSelect: ((SdkConnectLocation) -> Void)
    
    var body: some View {
        
        if (providerCountries.isEmpty) {
            VStack {
                ProgressView().progressViewStyle(CircularProgressViewStyle())
            }
            .background(themeManager.currentTheme.backgroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
            
                ForEach(providerCountries, id: \.connectLocationId) { provider in
                    
                    HStack {
                        
                        ProviderColorCircle(
                            color: getProviderColor(
                                locationType: provider.locationType,
                                countryCode: provider.countryCode,
                                id: provider.connectLocationId?.locationId?.idStr
                            ),
                            isStrongPrivacy: provider.strongPrivacy
                        )
                        
                        Spacer().frame(width: 16)
                        
                        Text(provider.name)
                        
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.onSelect(provider)
                    }
                    
                }
                
            }
            .listStyle(.inset)
            .background(themeManager.currentTheme.backgroundColor)
        }
        
    }
}

#Preview {
    AddBlockedLocationSheet(
        providerCountries: [],
        onSelect: {_ in }
    )
}
