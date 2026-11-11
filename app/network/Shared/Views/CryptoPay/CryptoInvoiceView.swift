//
//  CryptoInvoiceView.swift
//  URnetwork
//
//  The crypto invoice (mmm/ZCASH-CONTRACT.md §6.2, mmm/BTCPAY.md §17.6),
//  rendered from the SDK's CryptoInvoiceState through CryptoInvoiceDisplay, top
//  to bottom: the network line, the QR of the SDK's QR text with "Open in
//  wallet" (only for a URI the SDK's check passes), the exact amount and the
//  address with Copy, the memo (USDC and SOL) and the coin's network-only
//  warning, the countdown with "Refresh quote", the status steps, the wallets
//  that work (and the shielded-address note for Zcash), "Pay another way" and
//  Close.
//
//  A coin without a payment link (TAO) has no "Open in wallet": its QR code
//  holds the address alone, with a note that says so, and "Send exactly this
//  amount to this address." stands in its place, over the amount and the
//  address with their own "Copy amount" and "Copy address".
//
//  It swaps in over the billing surface that opened it, like the Stripe
//  checkout page, so closing the surface keeps the invoice (the account
//  screen's row and the next billing surface bring it back). The SDK polls
//  only while it shows (CryptoInvoiceStore.setVisible) and the app is active.
//  Paying happens in a wallet outside the app, so the VPN stays as it is.
//
//  Direct-download build only (ZCASH.md §0.1).
//

#if DIRECT_DOWNLOAD

import AppKit
import SwiftUI

extension CryptoInvoiceDisplay.Network {

    /// The invoice's first line, also under each coin of the More coins list.
    var title: String {
        switch self {
        case .usdcOnSolana:
            return String(localized: "USDC on Solana")
        case .zcashShielded:
            return String(localized: "Zcash, shielded")
        case .monero:
            return String(localized: "Monero")
        case .bittensor:
            return String(localized: "Bittensor network")
        case .bitcoin:
            return String(localized: "Bitcoin network")
        case .ethereum:
            return String(localized: "Ethereum mainnet")
        case .solana:
            return String(localized: "Solana (native SOL)")
        }
    }
}

extension PaymentMethod {

    /// The coin's network-only warning, shown with the address: a transfer on
    /// another network, or of another token, is not credited. Nil for Zcash and
    /// Monero, which have none, and for Card.
    var networkWarning: String? {
        switch self {
        case .usdcSolana:
            // USDC exists on many chains: a transfer on the wrong one is lost
            return String(localized: "Send USDC on the Solana network only. USDC sent on any other network will not arrive.")
        case .tao:
            return String(localized: "Send only TAO on the Bittensor network to this address. TAO sent on any other network won't be credited.")
        case .btc:
            return String(localized: "Send only Bitcoin on the Bitcoin network to this address. Bitcoin sent on any other network won't be credited.")
        case .eth:
            return String(localized: "Send only ETH on Ethereum mainnet to this address. Tokens and ETH on other networks, such as Base or Arbitrum, won't be credited.")
        case .sol:
            return String(localized: "Send only SOL on the Solana network to this address. Tokens, including USDC, won't be credited.")
        case .card, .zec, .xmr:
            return nil
        }
    }

    /// Why a coin without a payment link has no "Open in wallet", and what its
    /// QR code holds: TAO's note. Nil for any other method.
    var noPaymentLinkNote: String? {
        switch self {
        case .tao:
            return String(localized: "TAO has no payment link, so this QR code holds only the address. Enter the exact amount in your wallet.")
        default:
            return nil
        }
    }
}

extension CryptoInvoiceDisplay.Step {

    var title: String {
        switch self {
        case .waiting:
            return String(localized: "Waiting for your payment")
        case .seen:
            return String(localized: "Payment seen")
        case .confirming(let count, let required):
            return String(localized: "Confirming: \(count) of \(required)")
        case .paid:
            return String(localized: "Paid. Thank you!")
        }
    }
}

struct CryptoInvoiceView: View {

    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var store: CryptoInvoiceStore
    /// Hands the payment URI to the wallet app that handles its scheme; false
    /// when none does, and the QR stays on screen with nothing alarming said.
    var openExternal: (URL) -> Bool = { url in NSWorkspace.shared.open(url) }
    var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private enum CopiedField: Equatable {
        case amount
        case remaining
        case address
        case memo
    }

    @State private var copied: CopiedField? = nil

    var body: some View {
        let display = store.display
        VStack(spacing: 0) {
            header(display)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    content(display)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .bottom])
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(themeManager.currentTheme.backgroundColor)
        .accessibilityIdentifier("acceptance.cryptoInvoice")
        .onAppear {
            store.setVisible(true, .invoice)
        }
        .onDisappear {
            store.setVisible(false, .invoice)
        }
    }

    /// The network first ("USDC on Solana", "Zcash, shielded", "Monero"),
    /// as the invoice's title.
    private func header(_ display: CryptoInvoiceDisplay) -> some View {
        HStack {
            Group {
                if let network = display.network {
                    Text(network.title)
                } else {
                    Text("Get Pro")
                }
            }
            .font(themeManager.currentTheme.titleFont)
            .foregroundColor(themeManager.currentTheme.textColor)
            Spacer()
            Button(action: {
                store.closeInvoice()
            }) {
                Image(systemName: "xmark")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Close"))
            .accessibilityLabel("Close")
        }
        .padding()
    }

    @ViewBuilder
    private func content(_ display: CryptoInvoiceDisplay) -> some View {
        if display.isStarting {
            HStack {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                Spacer()
            }
            .padding(.vertical, 48)
        } else if display.inReview {
            // nothing else to do: support sorts it out
            Text("We received a payment that needs a manual check. Contact support and we'll sort it out.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 24)

            closeButton
        } else if display.isFailed {
            Text("Something went wrong. Please try again later.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            Spacer().frame(height: 24)

            payAnotherWayButton
        } else if display.isAwaitingStatus {
            // a resumed invoice before its first poll: nothing payable yet
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading...")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
            .padding(.vertical, 24)

            closeButton
        } else {
            paymentContent(display)
        }
    }

    @ViewBuilder
    private func paymentContent(_ display: CryptoInvoiceDisplay) -> some View {
        if display.unavailable, let method = display.method {
            Text("Paying with \(method.title) is temporarily unavailable. Try again later, or pay another way.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 16)
        }

        // the SDK's QR text: the server's URI, which the SDK checked pays this
        // address, or for a coin without a payment link the address alone
        if let text = display.qrText {
            HStack {
                Spacer()
                CryptoPaymentQrCode(text: text, size: 200)
                Spacer()
            }

            Spacer().frame(height: 12)

            if display.hasNoPaymentLink, let note = display.method?.noPaymentLinkNote {
                Text(verbatim: note)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 12)
            }
        }

        if let uri = display.paymentUri {
            UrButton(
                text: "Open in wallet",
                action: {
                    if let url = URL(string: uri) {
                        // no wallet for the scheme: the QR stays for a phone
                        _ = openExternal(url)
                    }
                },
                style: .outlineSecondary,
                accessibilityIdentifier: "acceptance.cryptoInvoice.openWallet"
            )

            Spacer().frame(height: 20)
        }

        // where "Open in wallet" would be: the amount and the address go into
        // the wallet by hand
        if display.hasNoPaymentLink, display.amount != nil {
            Text("Send exactly this amount to this address.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 16)
        }

        if let amount = display.amount, let value = display.amountValue {
            copyField(
                title: Text("Send exactly"),
                value: amount,
                copyValue: value,
                field: .amount,
                monospaced: false,
                copyTitle: display.hasNoPaymentLink ? Text("Copy amount") : Text("Copy")
            )
        }

        // short of the amount: the rest, to the same address, with Copy
        if let remaining = display.remaining, let value = display.remainingValue {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(remaining) more to send")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                copyButton(value, field: .remaining)
            }
            .padding(.bottom, 16)
        }

        if let address = display.address {
            copyField(
                title: Text("To this address"),
                value: address,
                copyValue: address,
                field: .address,
                monospaced: true,
                copyTitle: display.hasNoPaymentLink ? Text("Copy address") : Text("Copy")
            )
        }

        if let memo = display.memo {
            copyField(title: Text("Memo, if you send by hand"), value: memo, copyValue: memo, field: .memo, monospaced: true)
        }

        // scanning the QR picks the network; a transfer sent by hand from an
        // exchange does not
        if display.address != nil, let warning = display.method?.networkWarning {
            Text(verbatim: warning)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 16)
        }

        countdown(display)

        steps(display)

        if !display.wallets.isEmpty {
            Text("Wallets that work: \(ListFormatter.localizedString(byJoining: display.wallets))")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 8)
        }

        if display.showsZcashExchangeNote {
            Text("Exchanges such as Coinbase and Robinhood can't send to this shielded address. Send from a shielded wallet.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 8)
        }

        Spacer().frame(height: 16)

        if display.showsPayAnotherWay {
            payAnotherWayButton
        } else {
            closeButton
        }
    }

    // MARK: rows

    /// A labelled value with its copy button (`copyTitle`: Copy, or "Copy
    /// amount" and "Copy address" on an invoice that has both).
    private func copyField(title: Text, value: String, copyValue: String, field: CopiedField, monospaced: Bool, copyTitle: Text = Text("Copy")) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: value)
                    .font(monospaced ? .system(size: 13, design: .monospaced) : themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                copyButton(copyValue, field: field, title: copyTitle)
            }
        }
        .padding(.bottom, 16)
    }

    /// `title` (Copy), which reads "Copied" for a moment after a tap.
    private func copyButton(_ value: String, field: CopiedField, title: Text = Text("Copy")) -> some View {
        Button(action: {
            copyToPasteboard(value)
            copied = field
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copied == field {
                    copied = nil
                }
            }
        }) {
            if copied == field {
                Text("Copied")
                    .font(themeManager.currentTheme.secondaryBodyFont)
            } else {
                title
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(themeManager.currentTheme.accentColor)
    }

    @ViewBuilder
    private func countdown(_ display: CryptoInvoiceDisplay) -> some View {
        switch display.countdown {
        case .running(let time):
            HStack(alignment: .firstTextBaseline) {
                Text("Quote expires in \(time)")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .monospacedDigit()

                Spacer()

                if display.refresh != .hidden {
                    refreshLink(inFlight: display.refresh == .inFlight)
                }
            }

            Spacer().frame(height: 16)
        case .expired:
            Text("This quote expired. Refresh it for a new amount.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 12)

            if display.refresh != .hidden {
                UrButton(
                    text: "Refresh quote",
                    action: {
                        store.requote()
                    },
                    isProcessing: display.refresh == .inFlight,
                    accessibilityIdentifier: "acceptance.cryptoInvoice.refresh"
                )

                Spacer().frame(height: 16)
            }
        case nil:
            EmptyView()
        }
    }

    private func refreshLink(inFlight: Bool) -> some View {
        Button(action: {
            store.requote()
        }) {
            if inFlight {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Refresh quote")
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(themeManager.currentTheme.accentColor)
        .disabled(inFlight)
    }

    @ViewBuilder
    private func steps(_ display: CryptoInvoiceDisplay) -> some View {
        if !display.steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(display.steps.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        stepMark(row.progress)
                            .frame(width: 16, height: 16)

                        Text(row.step.title)
                            .font(row.progress == .current ? themeManager.currentTheme.bodyFont.bold() : themeManager.currentTheme.bodyFont)
                            .foregroundColor(row.progress == .upcoming ? themeManager.currentTheme.textFaintColor : themeManager.currentTheme.textColor)
                    }
                }

            }

            Spacer().frame(height: 20)
        }
    }

    @ViewBuilder
    private func stepMark(_ progress: CryptoInvoiceDisplay.StepProgress) -> some View {
        switch progress {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(themeManager.currentTheme.accentColor)
        case .current:
            ProgressView()
                .controlSize(.small)
        case .upcoming:
            Image(systemName: "circle")
                .foregroundColor(themeManager.currentTheme.textFaintColor)
        }
    }

    private var payAnotherWayButton: some View {
        HStack {
            Spacer()
            Button(action: {
                store.payAnotherWay()
            }) {
                Text("Pay another way")
                    .font(themeManager.currentTheme.bodyFont)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .accessibilityIdentifier("acceptance.cryptoInvoice.payAnotherWay")
            Spacer()
        }
    }

    private var closeButton: some View {
        UrButton(
            text: "Close",
            action: {
                store.closeInvoice()
            },
            style: .outlineSecondary
        )
    }
}

/// The invoice's QR text (the payment URI, or a TAO address) as a QR code, one
/// pixel per module and never smoothed, on a white quiet zone.
struct CryptoPaymentQrCode: View {

    let text: String
    let size: CGFloat

    // generated once per text, not on every body evaluation
    @State private var image: CGImage? = nil

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: size, height: size)
            }
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(8)
        // the amount and the address rows carry the same payment as text
        .accessibilityHidden(true)
        .onAppear {
            image = cryptoPaymentQrImage(text)
        }
        .onChange(of: text) { text in
            image = cryptoPaymentQrImage(text)
        }
    }
}

#endif
