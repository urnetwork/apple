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
    /// The trial line with its length ("Includes 14 day free trial"); only the yearly plan has one.
    var trialDays: Int? = nil
    /// The legacy green "Most Popular" pill, used by the upgrade sheet.
    /// The recommended plan: the Pro-gold dress and the "Best value" pill.
    var bestValue: Bool = false

    private var accent: Color {
        bestValue ? introProGold : .accent
    }
    
    var body: some View {
        
        ZStack {
         
            VStack(alignment: .leading) {
                
                HStack {
                    
                    // selected indicator
                    Circle()
                        .fill(isSelected ? accent : Color.clear)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? accent : themeManager.currentTheme.textMutedColor, lineWidth: 2)
                        )
                    
                    Spacer().frame(width: 18)
                    
                    VStack(alignment: .leading) {
                    
                        Text(price)
                            .font(Font.custom("PP NeueBit", size: 22).weight(.bold))
                        
                        if let trialDays {
                            Text("Includes \(trialDays) day free trial")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(introProGoldLight)
                        }
                        
                    }
                    
                    Spacer()
                    
                }
                
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                Group {
                    if bestValue {
                        Color.clear
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? .accent : themeManager.currentTheme.textFaintColor, lineWidth: 2)
                    }
                }
            )
            .modifier(OptionalGoldDress(enabled: bestValue, selected: isSelected))
            .animation(.easeInOut, value: isSelected)
            
        }
        .overlay(alignment: .topTrailing) {
            if bestValue {
                BestValuePill()
                    .padding(.horizontal, 8) // inset from edges
                    .offset(y: -16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            select()
        }
    }
}

/// The gold dress when the card is the recommended plan, nothing otherwise.
private struct OptionalGoldDress: ViewModifier {
    let enabled: Bool
    let selected: Bool
    func body(content: Content) -> some View {
        if enabled {
            // no clip here: the halo spills past the card on purpose
            content.goldPlanDress(selected: selected)
        } else {
            content.cornerRadius(8)
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        ProductOptionCard(price: "$39.99 Annual (Save 33%)", select: {}, isSelected: true, trialDays: 14, bestValue: true)
        ProductOptionCard(price: "$4.99/month", select: {}, isSelected: false)
    }
    .padding(24)
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
}
