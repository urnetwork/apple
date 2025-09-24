//
//  SelectedProvider.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/02/12.
//

import SwiftUI
import URnetworkSdk

struct SelectedProvider: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let selectedProvider: SdkConnectLocation?
    let openSelectProvider: () -> Void
    // var getProviderColor: (SdkConnectLocation) -> Color
    
    var body: some View {
        HStack {
            
            if let selectedProvider = selectedProvider, selectedProvider.connectLocationId?.bestAvailable != true {

                Image("ur.symbols.tab.connect")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(getProviderColor(selectedProvider))
                
                Spacer().frame(width: 16)
                
                VStack(alignment: .leading) {
                    Text(selectedProvider.name)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    if selectedProvider.providerCount > 0 {
    
                        Text("\(selectedProvider.providerCount) providers")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
    
                    
                }
            } else {
   
                Image("ur.symbols.tab.connect")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.urCoral)
                
                Spacer().frame(width: 16)
                
                VStack(alignment: .leading) {
                    Text("Best available provider")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
            }
            
//            Spacer().frame(width: 8)
            
            Spacer()
            
            Button(action: openSelectProvider) {
                Text("Change")
                    .foregroundStyle(.urElectricBlue)
                    .font(themeManager.currentTheme.bodyFont)
            }
            
        }
        .padding(.vertical, 8)
//        .padding(.horizontal, 16)
    }
}

#Preview {
    SelectedProvider(
        selectedProvider: nil,
        openSelectProvider: {}
    )
}
