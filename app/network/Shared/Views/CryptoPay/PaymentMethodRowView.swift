//
//  PaymentMethodRowView.swift
//  URnetwork
//
//  The method row (mmm/ZCASH-CONTRACT.md §6.1, mmm/BTCPAY.md §17.6): Card,
//  then the SDK's coin tabs (USDC on Solana, Zcash, Monero and More coins),
//  directly above a plan surface's buy button, with the list of coins a tab of
//  several coins opens, and the copy the button and its fine print take for a
//  coin. Direct-download build only: the App Store builds sell through
//  StoreKit with no method row and no crypto copy (ZCASH.md §0.1).
//

#if DIRECT_DOWNLOAD

import SwiftUI

extension PaymentMethod {

    /// The method's name on the row, in the button's {method} and on the
    /// invoice: Card, or the coin's name by its key in the localizations store
    /// (CryptoPayCopy.label).
    var title: String {
        if self == .card {
            return String(localized: "Card")
        }
        return CryptoPayCopy.label(key: sdkLabelKey, english: sdkLabel)
    }
}

/// The buy button and the fine print a coin shows in place of the card's.
enum CryptoPayCopy {

    /// "Pay with Monero".
    static func payButton(_ method: PaymentMethod) -> String {
        String(localized: "Pay with \(method.title)")
    }

    /// Under the button of a coin's yearly plan.
    static var finePrintYearly: String {
        String(localized: "A one-time payment for a year of Pro. It doesn't renew, and there's no free trial.")
    }

    /// The monthly plan's line while a coin is selected.
    static var monthlyCardOnly: String {
        String(localized: "Monthly is card only")
    }

    /// The success view's line once an invoice is paid, while the balance
    /// refresh confirms Pro (the line every non-store purchase shows).
    static var confirmingMessage: String {
        String(localized: "We're confirming your purchase. Your plan will update automatically.")
    }

    /// A start the server refused, in the surface's own words for the code
    /// (CheckoutRefusal, as the card checkout's refusals read).
    static func refusal(_ refusal: CryptoPurchaseRefusal) -> String {
        CheckoutRefusal.message(
            code: refusal.code,
            words: refusal.message,
            screenLine: String(localized: "Something went wrong. Please try again later.")
        )
    }

    /// A coin's or a tab's name by its string id in the localizations store
    /// (the SDK's LabelKey), or the SDK's English (`english`) for an id this
    /// app has no string for: a coin is never shown under another coin's
    /// name. The catalog has one entry per English text, so the USDC tab reads
    /// the entry the USDC invoice's first line has.
    static func label(key: String, english: String) -> String {
        switch key {
        case "pay_method_usdc_solana":
            return String(localized: "USDC on Solana")
        case "pay_method_zcash":
            return String(localized: "Zcash")
        case "pay_method_monero":
            return String(localized: "Monero")
        case "pay_method_tao":
            return String(localized: "TAO")
        case "pay_method_bitcoin":
            return String(localized: "Bitcoin")
        case "pay_method_eth":
            return String(localized: "ETH")
        case "pay_method_sol":
            return String(localized: "SOL")
        case "pay_method_more_coins":
            return String(localized: "More coins")
        default:
            return english
        }
    }

    /// A tab of several coins for VoiceOver, by the coins behind it: "More
    /// coins: TAO, Bitcoin, ETH and SOL".
    static func moreCoinsAccessibilityLabel(_ coins: [String]) -> String {
        String(localized: "More coins: \(ListFormatter.localizedString(byJoining: coins))")
    }
}

/// Card, then the SDK's coin tabs: USDC on Solana, Zcash, Monero and More
/// coins, whose TAO, Bitcoin, ETH and SOL marks are four separate marks with
/// space between them, never one badge. The tabs wrap where the surface is
/// narrow. A tab of several coins (More coins) opens their list under the
/// row, each coin with the network it is sent on. The selected method's tab
/// is the SDK's CryptoPaymentTabId of it (`row.selectedTabId`, "" for Card).
///
/// A tab or a coin that cannot be paid with now stays in its place, its name
/// greyed with "Temporarily unavailable", and cannot be chosen; its marks are
/// never dimmed. Hidden by its caller when no coin is listed.
struct PaymentMethodRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: PaymentMethodRowState
    let choose: (PaymentMethod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRow(horizontalSpacing: 8, verticalSpacing: 8) {
                MethodTabButton(
                    isSelected: row.selectedTabId.isEmpty,
                    isAvailable: true,
                    action: { choose(.card) }
                ) {
                    MethodTabName(name: PaymentMethod.card.title, isAvailable: true)
                }

                ForEach(row.tabs, id: \.id) { tab in
                    tabButton(tab)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pay with")
            .accessibilityIdentifier("acceptance.paymentMethod")

            // the list a tab of several coins opens
            if let tab = row.tabs.first(where: { $0.id == row.selectedTabId }), 1 < tab.coins.count {
                coinList(tab)
            }

            // the coin stays selectable for a retry
            if row.selectedUnavailable {
                Text("Temporarily unavailable")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
    }

    private func tabButton(_ tab: CryptoPayTab) -> some View {
        let marks = tab.iconKeys.compactMap { CryptoPaymentSdk.markImageName($0) }
        let coinNames = tab.coins.map { CryptoPayCopy.label(key: $0.labelKey, english: $0.label) }
        return MethodTabButton(
            isSelected: tab.id == row.selectedTabId,
            isAvailable: tab.available,
            accessibilityText: 1 < tab.coins.count ? CryptoPayCopy.moreCoinsAccessibilityLabel(coinNames) : nil,
            action: {
                if let method = PaymentMethodRules.choice(tab, selected: row.selected) {
                    choose(method)
                }
            }
        ) {
            HStack(spacing: 10) {
                if !marks.isEmpty {
                    // each mark on its own, with clear space around it
                    HStack(spacing: 8) {
                        ForEach(marks, id: \.self) { mark in
                            CoinMark(imageName: mark, size: 14)
                        }
                    }
                }
                MethodTabName(name: CryptoPayCopy.label(key: tab.labelKey, english: tab.label), isAvailable: tab.available)
            }
        }
    }

    /// The coins of a tab of several coins, titled with the tab's name.
    private func coinList(_ tab: CryptoPayTab) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: CryptoPayCopy.label(key: tab.labelKey, english: tab.label))
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            ForEach(tab.coins, id: \.asset) { coin in
                CoinChoiceRow(coin: coin, isSelected: coin.asset == row.selected.asset, choose: choose)
            }
        }
        .padding(.top, 6)
    }
}

/// One tab of the row: outlined, filled while selected. One that cannot be
/// chosen is no button at all, and nothing in it is dimmer than its name.
private struct MethodTabButton<Label: View>: View {

    @EnvironmentObject var themeManager: ThemeManager

    let isSelected: Bool
    let isAvailable: Bool
    /// What VoiceOver reads for the tab instead of what it shows.
    var accessibilityText: String? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        tab
            .voiceOverLabel(accessibilityText)
    }

    @ViewBuilder
    private var tab: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let content = label()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(isSelected ? themeManager.currentTheme.accentColor.opacity(0.2) : Color.clear, in: shape)
            .overlay {
                shape.stroke(isSelected ? themeManager.currentTheme.accentColor : themeManager.currentTheme.borderEmphasisColor, lineWidth: 1)
            }
            .contentShape(shape)
        if isAvailable {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }
}

/// A tab's name, greyed with "Temporarily unavailable" under it while none of
/// its coins can be paid with.
private struct MethodTabName: View {

    @EnvironmentObject var themeManager: ThemeManager

    let name: String
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(isAvailable ? themeManager.currentTheme.textColor : themeManager.currentTheme.textFaintColor)
                .lineLimit(1)

            if !isAvailable {
                Text("Temporarily unavailable")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
    }
}

/// A coin in the list a tab of several coins opens: its mark, its name, and
/// the network it is sent on. One that cannot be paid with now is greyed,
/// says "Temporarily unavailable", and cannot be chosen; its mark is the same.
private struct CoinChoiceRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let coin: CryptoPayCoin
    let isSelected: Bool
    let choose: (PaymentMethod) -> Void

    /// The network line ("Bittensor network"), or the coin's name for a coin
    /// this app has no line for.
    private var network: String {
        PaymentMethod(asset: coin.asset).flatMap(CryptoInvoiceDisplay.networkLine(for:))?.title
            ?? CryptoPayCopy.label(key: coin.labelKey, english: coin.label)
    }

    var body: some View {
        if coin.available {
            Button(action: {
                if let method = PaymentMethod(asset: coin.asset) {
                    choose(method)
                }
            }) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(isSelected ? themeManager.currentTheme.accentColor : themeManager.currentTheme.textFaintColor)
                .accessibilityHidden(true)

            if let mark = CryptoPaymentSdk.markImageName(coin.iconKey) {
                CoinMark(imageName: mark, size: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: CryptoPayCopy.label(key: coin.labelKey, english: coin.label))
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(coin.available ? themeManager.currentTheme.textColor : themeManager.currentTheme.textFaintColor)

                Text(verbatim: network)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                if !coin.available {
                    Text("Temporarily unavailable")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// A coin's mark, a template image of the asset catalog, at full contrast:
/// white in a dark appearance and black in a light one, and never dimmed.
/// Solana's and Bittensor's brand rules allow their marks only so, and all
/// four marks are shown the same way (mmm/BTCPAY.md §17.6).
private struct CoinMark: View {

    @Environment(\.colorScheme) private var colorScheme

    let imageName: String
    let size: CGFloat

    var body: some View {
        Image(imageName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundColor(colorScheme == .dark ? Color.white : Color.black)
            .accessibilityHidden(true)
    }
}

private extension View {

    /// VoiceOver reads `text` for the view instead of its contents, when there is one.
    @ViewBuilder
    func voiceOverLabel(_ text: String?) -> some View {
        if let text {
            self.accessibilityLabel(text)
        } else {
            self
        }
    }
}

#endif
