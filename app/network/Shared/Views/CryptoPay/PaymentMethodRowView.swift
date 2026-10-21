//
//  PaymentMethodRowView.swift
//  URnetwork
//
//  The method row (mmm/ZCASH-CONTRACT.md §6.1): Card · USDC · Zcash · Monero
//  as a segmented control, directly above a plan surface's buy button, and the
//  copy the button and its fine print take for a coin. Direct-download build
//  only: the App Store builds sell through StoreKit with no method row and no
//  crypto copy (ZCASH.md §0.1).
//

#if DIRECT_DOWNLOAD

import SwiftUI

extension PaymentMethod {

    /// The row's segment, and the button's {method}: Card, USDC, Zcash, Monero.
    var title: String {
        switch self {
        case .card:
            return String(localized: "Card")
        case .usdcSolana:
            return String(localized: "USDC")
        case .zec:
            return String(localized: "Zcash")
        case .xmr:
            return String(localized: "Monero")
        }
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
}

/// Card · USDC · Zcash · Monero. Hidden by its caller when no coin is listed.
struct PaymentMethodRowView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let row: PaymentMethodRowState
    let choose: (PaymentMethod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Pay with", selection: Binding(
                get: { row.selected },
                set: { method in choose(method) }
            )) {
                ForEach(row.methods, id: \.self) { method in
                    Text(method.title)
                        .tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("acceptance.paymentMethod")

            // the coin stays selectable for a retry
            if row.selectedUnavailable {
                Text("Temporarily unavailable")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
    }
}

#endif
