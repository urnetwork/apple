//
//  ClaimLedgerSheet.swift
//  URnetwork
//
//  The settlement v2 claim dialog, beside the v1 one. The SDK on this device
//  claims every finalized v2 account of the coldkey with a verified
//  claimable, the provider pool's and the capture the flag pool's alike, from
//  the gas key: one transaction to STSettlementVault2 for one account, one
//  STClaimBatcher transaction for two or more ("Claim both"); alpha lands on
//  the connected coldkey. Shows the claimable total (none, never 0, while
//  what is left is all under the floor, unavailable or of an amount not known
//  yet), the gas key and its TAO balance (with the top-up when short or when a
//  claim needed gas), each pool's claim state with its transaction on the
//  explorer once sent, a pool that could not be read as unavailable right
//  now, and the failures.
//

import SwiftUI

struct ClaimLedgerSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL
    @ObservedObject var viewModel: EarningsViewModel
    let dismiss: () -> Void

    /// the ledger could not be read again, or nothing in it could: no amount,
    /// never 0
    private var unavailable: Bool {
        viewModel.ledgerClaimUnavailable
    }

    /// the claim's total is a figure to show: with nothing above the floor
    /// left and an account under it, unavailable or of an amount not known
    /// yet, the lines say why, and there is no figure, never 0
    private var totalKnown: Bool {
        viewModel.ledgerClaimTotalKnown
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

                if unavailable {
                    VStack(alignment: .leading, spacing: 0) {
                        UrLabel(text: "Claimable")
                        Text("Unavailable")
                            .font(themeManager.currentTheme.titleCondensedFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                } else if totalKnown {
                    VStack(alignment: .leading, spacing: 0) {
                        UrLabel(text: "Claimable")
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
                } else if unavailable || (!totalKnown && !viewModel.isLedgerClaiming) {
                    // no amount to name: never a Claim of 0
                    UrButton(text: "Claim", action: {}, enabled: false)
                } else {
                    UrButton(
                        text: viewModel.ledgerClaimsBoth ? "Claim both" : "Claim \(amountText)",
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
                Text(verbatim: row.name.text())
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
                if row.status == .unavailable {
                    // in place of the amount, never 0
                    Text("Unavailable right now")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                } else {
                    // no figure for an amount not known yet, never 0
                    if let amountRao = row.amountRao {
                        Text(verbatim: viewModel.client.formatAlpha(rao: amountRao))
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                    if row.status != .underFloor {
                        LedgerClaimStatusPill(status: row.status)
                    }
                }
            }
            // a line, not a pill: it is long in many languages
            if row.status == .underFloor {
                LedgerUnderFloorLine()
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

/// "Below the claim minimum", under a pool's row: no claim can move its
/// balance until it is worth the transfer floor; it waits in the vault.
struct LedgerUnderFloorLine: View {

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        Text("Below the claim minimum")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
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
        case .underFloor:
            return Text("Below the claim minimum")
        case .unavailable:
            return Text("Unavailable right now")
        }
    }

    private var color: Color {
        switch status {
        case .unclaimed:
            return introProGold
        case .pending, .sent, .underFloor, .unavailable:
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
            SnLedgerAccountInfo(vault: vault2, noId: 4_294_967_297, index: 7, finalizedRao: 144_076_980, claimableRao: 144_076_980, paidRao: 0, pending: false, pendingRao: 0, kind: .ctf),
        ],
        ledgerChain: SnLedgerChainInfo(vault2Address: vault2, explorerTxUrl: "https://evm.taostats.io/tx/%s")
    )
    ClaimLedgerSheet(viewModel: EarningsViewModel(client: client), dismiss: {})
        .environmentObject(themeManager)
}
