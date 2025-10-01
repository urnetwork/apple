//
//  ProductOptionCard.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/27/25.
//

import SwiftUI
import StoreKit

struct ProductOptionCard: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let title: String
    let price: String
    let select: () -> Void
    let isSelected: Bool
    
    var body: some View {
        
        VStack(alignment: .leading) {
            
            HStack {
                Text(title)
                
                Spacer()
                
                Text(price)
            }
            
        }
        .padding()
        .background(
            
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.gray, lineWidth: isSelected ? 3 : 1)
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .overlay(
                    // lighten selected
                    Rectangle()
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.white.opacity(0.0))
                        .blendMode(.screen)
                )
                // .background(isSelected ? Color.accentColor.opacity(0.1) : themeManager.currentTheme.tintedBackgroundBase)
        )
        .animation(.easeInOut, value: isSelected)
//        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(8)
        .onTapGesture {
            select()
        }
        
    }
}

//#Preview {
//    ProductOptionCard()
//}
