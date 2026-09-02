//
//  ClaimAlphaSheet.swift
//  URnetwork
//
//  The claim dialog. The SDK on this device sends each finalized epoch's
//  claim straight to the settlement vault from the gas key; alpha lands on the
//  connected coldkey. Shows the unclaimed total, the gas key and its TAO
//  balance (with the funding hint when short), the epochs and their claim
//  states, and the failures.
//

import SwiftUI

struct ClaimAlphaSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var viewModel: EarningsViewModel
    let dismiss: () -> Void

    @State private var copiedMirror = false

    private var claimableCount: Int {
        viewModel.claimableClaims.count
    }

    private var amountText: String {
        viewModel.client.formatAlpha(rao: viewModel.totalClaimableRao)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                Text("Claim SN25α")
                    .font(themeManager.currentTheme.toolbarTitleFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                VStack(alignment: .leading, spacing: 0) {
                    UrLabel(text: "Unclaimed")
                    Text(verbatim: amountText)
                        .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Text("Across \(claimableCount) finalized epochs")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Claims open 48 hours after an epoch is finalized and stay open for the vault's expiry window.")
                    Text("Your device sends the claim to the vault contract. Gas is paid in TAO from your gas key. Alpha lands on your coldkey.")
                }
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)

                gasCard

                if !viewModel.claims.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(viewModel.claims) { claim in
                            claimRow(claim)
                            if claim.id != viewModel.claims.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(12)
                }

                ForEach(viewModel.claimFailureMessages, id: \.epoch) { failure in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(themeManager.currentTheme.dangerColor)
                        failureText(epoch: failure.epoch, message: failure.message)
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textColor)
                    }
                }

                if viewModel.claimFinished {
                    UrButton(text: "Done", action: {
                        viewModel.resetClaimProgress()
                        dismiss()
                    })
                } else {
                    UrButton(
                        text: "Claim \(amountText)",
                        action: {
                            viewModel.claimAll()
                        },
                        enabled: claimableCount > 0 && !viewModel.needsGas && !viewModel.isClaiming,
                        isProcessing: viewModel.isClaiming
                    )
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    private var gasCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            UrLabel(text: "Gas key")
            if let gasKey = viewModel.gasKey {
                HStack {
                    Text(verbatim: viewModel.client.shortSs58(gasKey.mirrorSs58))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Button(action: {
                        EarningsClipboard.copy(gasKey.mirrorSs58)
                        copiedMirror = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            copiedMirror = false
                        }
                    }) {
                        Image(systemName: copiedMirror ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if let gasTao = viewModel.gasTao {
                        Text(verbatim: SnAlpha.formatTao(gasTao))
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundColor(viewModel.needsGas ? Color.urAmber : themeManager.currentTheme.textColor)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if viewModel.needsGas {
                    Text("Add TAO for gas")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(.urAmber)
                    Text("Send about \(String(format: "%.4f", viewModel.gasNeededTao)) TAO to \(gasKey.mirrorSs58) to cover gas.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            } else {
                Text("The chain RPC is unreachable. Try again.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private func claimRow(_ claim: SnEpochClaimInfo) -> some View {
        HStack {
            Text("Epoch \(claim.epoch)")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Spacer()
            Text(verbatim: viewModel.client.formatAlpha(rao: claim.amountRao))
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            ClaimStatusPill(status: claim.status, progress: viewModel.claimProgress[claim.epoch])
        }
        .padding(.vertical, 12)
    }

    /// Failures start with a stable code, then ": " and the detail.
    private func failureText(epoch: Int64, message: String) -> Text {
        let code = message.components(separatedBy: ": ").first?.trimmingCharacters(in: .whitespaces) ?? message
        switch code {
        case "needs_gas":
            return Text("Add TAO for gas")
        case "claims_for_epoch_expired":
            return Text("Claims for epoch \(epoch) have expired.")
        case "already_claimed":
            return Text("Claimed")
        case "chain_rpc_unreachable", "artifact_unavailable", "chain_not_configured":
            return Text("The chain RPC is unreachable. Try again.")
        case "connect_wallet_first", "local_state_unavailable":
            return Text("Connect a Bittensor wallet first.")
        default:
            let lower = message.lowercased()
            if lower.contains("expired") {
                return Text("Claims for epoch \(epoch) have expired.")
            }
            if lower.contains("gas") {
                return Text("Add TAO for gas")
            }
            if lower.contains("rpc") || lower.contains("unreachable") {
                return Text("The chain RPC is unreachable. Try again.")
            }
            return Text(verbatim: message)
        }
    }
}

/// The claim state of one epoch: the vault's status, overlaid by the live
/// claim progress while a claim runs.
struct ClaimStatusPill: View {

    @EnvironmentObject var themeManager: ThemeManager
    let status: SnClaimStatus
    var progress: EarningsViewModel.ClaimRowState? = nil

    private var label: Text {
        if let progress {
            switch progress {
            case .queued:
                return Text("Pending")
            case .sent:
                return Text("Sent")
            case .confirmed:
                return Text("Claimed")
            case .failed:
                return Text("Failed")
            }
        }
        switch status {
        case .claimable:
            return Text("Unclaimed")
        case .claimed:
            return Text("Claimed")
        case .expired:
            return Text("Expired")
        case .open, .notFinalized:
            return Text("Pending")
        }
    }

    private var color: Color {
        if let progress {
            switch progress {
            case .queued, .sent:
                return themeManager.currentTheme.textMutedColor
            case .confirmed:
                return themeManager.currentTheme.accentColor
            case .failed:
                return themeManager.currentTheme.dangerColor
            }
        }
        switch status {
        case .claimable:
            return introProGold
        case .claimed:
            return themeManager.currentTheme.accentColor
        case .expired:
            return themeManager.currentTheme.dangerColor
        case .open, .notFinalized:
            return themeManager.currentTheme.textMutedColor
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
    let client = EarningsPreviewClient(
        wallet: SnWalletInfo(coldkeySs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY", clientId: "", setAtMillis: 0),
        claims: [
            SnEpochClaimInfo(epoch: 42, shareBps: 71, amountRao: 3_241_000_000, status: .claimable, claimOpenBlock: 0, expiryBlock: 0, txHash: ""),
            SnEpochClaimInfo(epoch: 41, shareBps: 65, amountRao: 2_900_000_000, status: .claimed, claimOpenBlock: 0, expiryBlock: 0, txHash: "0x1"),
        ],
        gasTao: 0.002
    )
    ClaimAlphaSheet(viewModel: EarningsViewModel(client: client), dismiss: {})
        .environmentObject(themeManager)
}
