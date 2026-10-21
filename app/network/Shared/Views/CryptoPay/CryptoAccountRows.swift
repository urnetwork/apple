//
//  CryptoAccountRows.swift
//  URnetwork
//
//  The account screen's crypto lines (mmm/ZCASH-CONTRACT.md §6.2):
//  - a saved invoice that isn't paid gets a row that opens it, with its
//    network and its status step kept current while the row shows;
//  - while a paid crypto year has ended and its grace has not
//    (term_end <= now < grace_end, never before), "Your paid year of Pro has
//    ended. Renew by {date} to keep Pro." with Renew, which opens the upgrade
//    surface. In the plan area, never a system notification.
//
//  Direct-download build only (ZCASH.md §0.1).
//

#if DIRECT_DOWNLOAD

import SwiftUI

/// The invoice in progress, as a row that opens it.
struct CryptoPaymentInProgressRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var store: CryptoInvoiceStore
    let open: () -> Void

    var body: some View {
        let display = store.display
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Payment in progress")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)

                    // the network, and where the payment is
                    HStack(spacing: 6) {
                        if let network = display.network {
                            Text(network.title)
                        }
                        if !display.inReview, let step = display.currentStep {
                            if display.network != nil {
                                Text(verbatim: "·")
                            }
                            Text(step.title)
                        }
                    }
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                    if display.inReview {
                        Text("We received a payment that needs a manual check. Contact support and we'll sort it out.")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("acceptance.account.cryptoPayment")
        // the status is current while the row shows (and the app is active)
        .onAppear {
            store.setVisible(true, .accountRow)
        }
        .onDisappear {
            store.setVisible(false, .accountRow)
        }
    }
}

/// The paid crypto year has ended: renew within the grace to keep Pro.
struct CryptoTermNotice: View {

    @EnvironmentObject var themeManager: ThemeManager

    let term: CryptoTerm
    let renew: () -> Void

    var body: some View {
        // the notice starts when the term ends, without a reload: the SDK's
        // rule, asked again every minute
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            if CryptoPaymentSdk.termNoticeDue(term), let graceEnd = term.graceEnd {
                let date = graceEnd.formatted(date: .long, time: .omitted)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your paid year of Pro has ended. Renew by \(date) to keep Pro.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: renew) {
                        Text("Renew")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                    }
                    .accessibilityIdentifier("acceptance.account.cryptoRenew")
                }
                .padding(.vertical, 8)
            }
        }
    }
}

#endif
