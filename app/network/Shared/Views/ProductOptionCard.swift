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
    /// A card without a trial line reserves the height of one (the other card's), so the two
    /// plan cards are equal height at any text size, with the visible line centered in that
    /// space, level with the radio dot.
    var reservedTrialDays: Int? = nil
    /// The legacy green "Most Popular" pill, used by the upgrade sheet.
    /// The recommended plan: the Pro-gold dress and the "Best value" pill.
    var bestValue: Bool = false

    private var accent: Color {
        bestValue ? introProGold : .accent
    }

    private var priceFont: Font {
        Font.custom("PP NeueBit", size: 22).weight(.bold)
    }

    private func trialLine(_ days: Int) -> some View {
        Text("Includes \(days) day free trial")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(introProGoldLight)
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

                    if let trialDays {
                        VStack(alignment: .leading) {
                            Text(price)
                                .font(priceFont)
                            trialLine(trialDays)
                        }
                    } else if let reservedTrialDays {
                        // the other card's two lines, invisible, size this card; the one
                        // visible line sits in the middle of that space
                        ZStack(alignment: .leading) {
                            VStack(alignment: .leading) {
                                Text(price)
                                    .font(priceFont)
                                trialLine(reservedTrialDays)
                            }
                            .hidden()
                            .accessibilityHidden(true)
                            Text(price)
                                .font(priceFont)
                        }
                    } else {
                        Text(price)
                            .font(priceFont)
                    }

                    Spacer()

                }

            }
            .frame(maxWidth: .infinity)
            // taller than wide: the plan lines get room to breathe
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
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

/// The gold dress when the card is the recommended plan, nothing otherwise. When that plan is
/// the selected one the dress blends in the purple selection language, so the pick reads as
/// selected and not only through the radio dot.
private struct OptionalGoldDress: ViewModifier {
    let enabled: Bool
    let selected: Bool
    func body(content: Content) -> some View {
        if enabled {
            // no clip here: the halo spills past the card on purpose
            content.goldPlanDress(selected: selected, blendSelection: selected)
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
