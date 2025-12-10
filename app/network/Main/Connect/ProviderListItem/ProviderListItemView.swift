//
//  ProviderListItem.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/11.
//

import SwiftUI
import URnetworkSdk

struct ProviderListItemView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let name: String
    let providerCount: Int32?
    let color: Color
    let isSelected: Bool
    let connect: () -> Void
    let isStable: Bool
    let isStrongPrivacy: Bool
    var displayIcons: Bool = true
    
    #if os(iOS)
    let padding: CGFloat = 16
//    let circleWidth: CGFloat = 40
    #elseif os(macOS)
    let padding: CGFloat = 0
//    let circleWidth: CGFloat = 30
    #endif
    
    var body: some View {
        HStack {
            
            ProviderColorCircle(
                color: color,
            )
            
            Spacer().frame(width: 16)
            
            VStack(alignment: .leading) {
                Text(name)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                HStack(spacing: 0) {
                 
                    if let providerCount = providerCount, providerCount > 0 {
                        Text("\(providerCount) providers")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    
                }
                
            }
            
            Spacer()
            
            HStack {
                
                if (!isStable) {
                 
                    /**
                     * stability
                     */
                    Image("ur.symbols.unstable")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(isStable ? themeManager.currentTheme.textMutedColor : .urLightYellow)
                        .frame(width: 20, height: 20)
                        .clipped()
                    
                }
                
                if (isStrongPrivacy) {
                    
                    Spacer().frame(width: 8)
                 
                    /**
                     * strong privacy
                     */
                    Image("ur.symbols.privacy")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.urGreen)
                        .frame(width: 20, height: 20)
                        .clipped()
                    
                }
                
                Spacer().frame(width: 16)
                
                Image(systemName: "checkmark")
                    .foregroundColor(isSelected ? .urElectricBlue : .clear)
                    .font(.system(size: 20))
            
                
            }
            
        }
        .padding(.vertical, 8)
        .padding(.horizontal, padding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            connect()
        }
        .listRowBackground(Color.clear)
    }
}

#Preview {
    
    let themeManager = ThemeManager.shared
    
    VStack {
        ProviderListItemView(
            name: "Tokyo",
            providerCount: 1000,
            color: Color (hex: "CC3363"),
            isSelected: true,
            connect: {},
            isStable: true,
            isStrongPrivacy: true
        )
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
}
