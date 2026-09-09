//
//  ProductOptionCard.swift
//  URnetwork
//

import SwiftUI

/// One plan card: the radio dot, the price line and the lines under it, centered
/// vertically next to the dot; the recommended plan wears the gold dress and the pill.
struct ProductOptionCard: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    /// The price line ("$39.99/year", "$29.99 for your first year").
    let title: String
    /// The lines under the price: the per-month equivalent, the renewal price, the trial.
    var lines: [String] = []
    let select: () -> Void
    let isSelected: Bool
    /// A card with fewer lines reserves the height of the other card's, so the two
    /// plan cards are equal height at any text size, with the visible lines centered
    /// in that space, level with the radio dot.
    var reservedLineCount: Int = 0
    /// The recommended plan: the Pro-gold dress and the pill.
    var bestValue: Bool = false
    /// The pill's text on the recommended plan ("Save 33%", "Best value").
    var pill: String = String(localized: "Best value")
    /// The line under the trial line on the offer card: the static deadline.
    var deadline: String? = nil

    private var accent: Color {
        bestValue ? introProGold : .accent
    }

    private var priceFont: Font {
        Font.custom("PP NeueBit", size: 22).weight(.bold)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(bestValue ? introProGoldLight : themeManager.currentTheme.textMutedColor)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(priceFont)
            ForEach(lines, id: \.self) { text in
                line(text)
            }
            if let deadline {
                Text(deadline)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .padding(.top, 4)
            }
        }
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

                    if reservedLineCount > lines.count {
                        // the other card's lines, invisible, size this card; the
                        // visible lines sit in the middle of that space
                        ZStack(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(priceFont)
                                ForEach(0..<reservedLineCount, id: \.self) { _ in
                                    line(" ")
                                }
                            }
                            .hidden()
                            .accessibilityHidden(true)
                            content
                        }
                    } else {
                        content
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
                BestValuePill(text: pill)
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
        ProductOptionCard(
            title: "$39.99/year",
            lines: ["≈ $3.34/month · billed once a year", "Includes 14 day free trial"],
            select: {},
            isSelected: true,
            bestValue: true,
            pill: "Save 33%"
        )
        ProductOptionCard(title: "$4.99/month", lines: ["Billed monthly · cancel anytime"], select: {}, isSelected: false, reservedLineCount: 2)
    }
    .padding(24)
    .background(Color.urBlack)
    .environmentObject(ThemeManager.shared)
}
