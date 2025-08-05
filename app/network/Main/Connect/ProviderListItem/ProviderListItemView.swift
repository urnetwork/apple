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
    
    var name: String
    var providerCount: Int32?
    var color: Color
    var isSelected: Bool
    var connect: () -> Void
    
    #if os(iOS)
    let padding: CGFloat = 16
//    let circleWidth: CGFloat = 40
    #elseif os(macOS)
    let padding: CGFloat = 0
//    let circleWidth: CGFloat = 30
    #endif
    
    var body: some View {
        HStack {
            
            ProviderColorCircle(color)
            
            Spacer().frame(width: 16)
            
            VStack(alignment: .leading) {
                Text(name)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                
                if let providerCount = providerCount, providerCount > 0 {
                    Text("\(providerCount) providers")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(.blue)
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
            connect: {}
        )
    }
    .environmentObject(themeManager)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(themeManager.currentTheme.backgroundColor)
}
