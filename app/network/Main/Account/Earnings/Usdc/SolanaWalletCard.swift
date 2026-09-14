//
//  SolanaWalletCard.swift
//  URnetwork
//
//  The Solana wallet USDC payouts go to until the migration to Bittensor is
//  complete: the address with copy, the Default badge, the migration note,
//  the USDC still waiting and the way to remove the wallet. A legacy Polygon
//  payout wallet shows on the same card with the Polygon logo.
//

import SwiftUI

struct SolanaWalletCard: View {

    @EnvironmentObject var themeManager: ThemeManager

    let wallet: UsdcWalletInfo
    let pendingUsd: String?
    /// a removal is in flight: the options stay closed until it finishes
    var isRemoving: Bool = false
    let remove: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                WalletIcon(blockchain: wallet.chain.rawValue, size: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        UrLabel(text: wallet.chain == .sol ? "Solana wallet" : "Wallet")
                        Spacer()
                        PayoutWalletTag(isPayoutWallet: true)
                        WalletOverflowMenu(
                            style: .plain,
                            accessibilityIdentifier: "acceptance.earnings.solanaWalletOptions"
                        ) {
                            Button("Remove", role: .destructive, action: remove)
                        }
                        .disabled(isRemoving)
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: SnAlpha.shortSs58(wallet.address))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.textColor)
                            .accessibilityLabel(Text(verbatim: wallet.address))
                        Button(action: copyAddress) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Copy"))
                        Spacer()
                    }
                }
            }
            Text("USDC payouts continue to this wallet until the migration to Bittensor is complete.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            if let pendingUsd {
                Text("\(pendingUsd) USDC waiting")
                    .font(themeManager.currentTheme.bodyFontLarge)
                    .foregroundColor(themeManager.currentTheme.textColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private func copyAddress() {
        EarningsClipboard.copy(wallet.address)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            copied = false
        }
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    SolanaWalletCard(
        wallet: UsdcWalletInfo(
            id: "preview-wallet",
            chain: .sol,
            address: UsdcWalletsPreviewClient.sampleAddress,
            hasSeekerToken: false
        ),
        pendingUsd: "3.87",
        remove: {}
    )
    .environmentObject(themeManager)
    .padding()
    .background(themeManager.currentTheme.backgroundColor)
}
