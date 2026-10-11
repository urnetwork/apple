//
//  ClaimLedgerSheet.swift
//  URnetwork
//
//  The settlement v2 claim dialog, beside the v1 one. The SDK on this device
//  claims every finalized v2 account of the coldkey with a verified
//  claimable, one transaction per pool to STSettlementVault2 from the gas
//  key; alpha lands on the connected coldkey. Shows the claimable total, the
//  gas key and its TAO balance (with the top-up when short or when a claim
//  needed gas), each pool's claim state with its transaction on the explorer
//  once sent, and the failures.
//

import SwiftUI

struct ClaimLedgerSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: EarningsViewModel
    let dismiss: () -> Void

    /// the ledger could not be read again: no amount, never 0
    private var unavailable: Bool {
        viewModel.ledger == .unavailable
    }

    private var amountText: String {
        viewModel.client.formatAlpha(rao: viewModel.ledgerClaimableRao)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 4) {
                    UrLabel(text: "Settlement v2")
                    Text("Claim SN25α")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }

                VStack(alignment: .leading, spacing: 0) {
                    UrLabel(text: "Claimable")
                    if unavailable {
                        Text("Unavailable")
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    } else {
                        Text(verbatim: amountText)
                            .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                }

                Text("Your device sends the claim to the vault contract. Gas is paid in TAO from your gas key. Alpha lands on your coldkey.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                ClaimGasCard(
                    gasKey: viewModel.gasKey,
                    gasTao: viewModel.gasTao,
                    needsGas: viewModel.ledgerNeedsGas,
                    gasNeededTao: viewModel.ledgerGasNeededTao,
                    shortSs58: viewModel.client.shortSs58
                )

                let rows = viewModel.ledgerClaimRows
                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            claimRow(row)
                            if row.id != rows.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(12)
                }

                ForEach(viewModel.ledgerClaimFailures, id: \.key) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(themeManager.currentTheme.dangerColor)
                        failureText(entry.failure)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                }

                if viewModel.ledgerClaimFinished {
                    UrButton(text: "Done", action: {
                        viewModel.resetLedgerClaimProgress()
                        dismiss()
                    })
                } else if unavailable {
                    UrButton(text: "Claim", action: {}, enabled: false)
                } else {
                    UrButton(
                        text: "Claim \(amountText)",
                        action: {
                            viewModel.claimLedger()
                        },
                        enabled: viewModel.ledgerClaimEnabled,
                        isProcessing: viewModel.isLedgerClaiming
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    private func claimRow(_ row: SnLedgerClaimRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pool \(row.id.noId)")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                Text(verbatim: viewModel.client.formatAlpha(rao: row.amountRao))
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                LedgerClaimStatusPill(status: row.status)
            }
            if let explorerUrl = row.explorerUrl {
                Button(action: {
                    openURL(explorerUrl)
                }) {
                    HStack(spacing: 4) {
                        Text("Transaction")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
    }

    /// The words the v1 claim dialog uses for the same failure.
    private func failureText(_ failure: SnLedgerClaimFailure) -> Text {
        switch failure {
        case .needsGas:
            return Text("Add TAO for gas")
        case .unreachable:
            return Text("The chain RPC is unreachable. Try again.")
        case .connectWallet:
            return Text("Connect a Bittensor wallet first.")
        case .message(let message):
            return Text(verbatim: message)
        }
    }
}

/// The claim state of one pool's v2 account: what the ledger says,
/// overlaid by the live claim progress while a claim runs.
struct LedgerClaimStatusPill: View {

    @EnvironmentObject var themeManager: ThemeManager
    let status: SnLedgerClaimStatus

    private var label: Text {
        switch status {
        case .unclaimed:
            return Text("Unclaimed")
        case .pending:
            return Text("Pending")
        case .sent:
            return Text("Sent")
        case .claimed:
            return Text("Claimed")
        case .failed:
            return Text("Failed")
        }
    }

    private var color: Color {
        switch status {
        case .unclaimed:
            return introProGold
        case .pending, .sent:
            return themeManager.currentTheme.textMutedColor
        case .claimed:
            return themeManager.currentTheme.accentColor
        case .failed:
            return themeManager.currentTheme.dangerColor
        }
    }

    var body: some View {
        label
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

#Preview {
    let themeManager = ThemeManager.shared
    let vault2 = "0x2222222222222222222222222222222222222222"
    let client = EarningsPreviewClient(
        wallet: SnWalletInfo(coldkeySs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY", clientId: "", setAtMillis: 0),
        gasTao: 0.05,
        ledger: [
            SnLedgerAccountInfo(vault: vault2, noId: 1, index: 42, finalizedRao: 5_000_000_000, claimableRao: 3_241_000_000, paidRao: 1_759_000_000, pending: true, pendingRao: 5_500_000_000),
        ],
        ledgerChain: SnLedgerChainInfo(vault2Address: vault2, explorerTxUrl: "https://evm.taostats.io/tx/%s")
    )
    ClaimLedgerSheet(viewModel: EarningsViewModel(client: client), dismiss: {})
        .environmentObject(themeManager)
}
