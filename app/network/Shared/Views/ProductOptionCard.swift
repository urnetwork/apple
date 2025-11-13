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
    
    let price: String
    let select: () -> Void
    let isSelected: Bool
    let includesFreeTrial: Bool
    let isMostPopular: Bool
    
    var body: some View {
        
        ZStack {
         
            VStack(alignment: .leading) {
                
                HStack {
                    
                    // selected indicator
                    Circle()
                        .fill(isSelected ? .accent : Color.clear)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? .accent : themeManager.currentTheme.textMutedColor, lineWidth: 2)
                        )
                    
                    Spacer().frame(width: 18)
                    
                    VStack(alignment: .leading) {
                    
                        Text(price)
                            .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
                        
                        if (includesFreeTrial) {
                            Text("Includes 2 week free trial")
                                .font(Font.custom("PP NeueBit", size: 18).weight(.bold))
                        }
                        
                    }
                    
                    Spacer()
                    
                }
                
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? .accent : themeManager.currentTheme.textFaintColor, lineWidth: 2)

            )
            .animation(.easeInOut, value: isSelected)
            .cornerRadius(8)
            
        }
        .overlay(alignment: .topTrailing) {
            if isMostPopular {
                Text("Most Popular")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.urGreen, in: Capsule())
                    .foregroundStyle(.urBlack)
                    .padding(.horizontal, 8) // inset from edges
                    .offset(y: -16)
                    .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
            }
        }
        .onTapGesture {
            select()
        }
        
    }
}

