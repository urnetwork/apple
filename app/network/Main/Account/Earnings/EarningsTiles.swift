//
//  EarningsTiles.swift
//  URnetwork
//
//  The tiles of the Earnings screen: the Top 200 head
//  spot, the Bittensor wallet block, the unclaimed alpha tile and the epoch
//  history rows.
//

import SwiftUI

/// The head-miner spot. Eligible and not yet bound: the gold call to claim
/// the spot on ur.io. Bound: the UID and rank, with the eviction warning
/// when the score sits close to the floor.
struct Top200Tile: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    let head: SnHeadInfo

    static let top200Url = "https://ur.io/app/account/top200"

    var body: some View {
        if head.bound {
            boundStatus
        } else if head.eligible {
            eligibleTile
        }
    }

    private var eligibleTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top 200")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .bold))
                .kerning(1.5)
                .foregroundColor(introProGoldLight)
            Text("You qualify")
                .font(Font.custom("PP NeueBit", size: 28).weight(.bold))
                .foregroundColor(.white)
            Text("Your network's routable IP breadth ranks about #\(head.rankEstimate) of \(head.cutoff) head spots. Head miners earn SN25α natively, every tempo.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(Color.white.opacity(0.85))
            Spacer().frame(height: 4)
            Button(action: {
                if let url = URL(string: Self.top200Url) {
                    openURL(url)
                }
            }) {
                HStack(spacing: 6) {
                    Text("Claim your spot")
                        .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.urReferralGoldInk)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(introProGold)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .goldPlanDress(cornerRadius: 12)
        .padding(.vertical, 8)
    }

    private var boundStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                UrLabel(text: "Top 200")
                Spacer()
                Image(systemName: "crown.fill")
                    .foregroundColor(introProGold)
            }
            Text("UID \(head.uid) · rank #\(head.rank)")
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundColor(themeManager.currentTheme.textColor)
            Text("Emission is paid to your coldkey directly. Bindings renew per epoch.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            if head.nearEvictionFloor {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.urAmber)
                    Text("Your score is close to the eviction floor. Add routable IPs to keep the spot.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(.urAmber)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }
}

/// The Bittensor wallet block: the connect call when none is attached, the
/// coldkey and the settlement note once it is.
struct BittensorWalletCard: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    let wallet: SnWalletInfo?
    let shortAddress: (String) -> String
    let connect: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UrLabel(text: "Bittensor wallet")
            if let wallet {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(themeManager.currentTheme.accentColor)
                    Text(verbatim: shortAddress(wallet.coldkeySs58))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Button(action: {
                        EarningsClipboard.copy(wallet.coldkeySs58)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            copied = false
                        }
                    }) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Text("Connected to the UR protocol. Claims land here. Alpha accrues from the next epoch after connecting.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            } else {
                WalletNotRetroactiveNote()
                Spacer().frame(height: 4)
                UrButton(text: "Connect Bittensor wallet", action: connect)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }
}

/// Alpha waiting in the vault. Only shown once a wallet is attached; alpha
/// is not retroactive.
struct UnclaimedAlphaTile: View {

    @EnvironmentObject var themeManager: ThemeManager

    let totalClaimableRao: Int64
    let claimableEpochs: Int
    let claim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            UrLabel(text: "Unclaimed")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: SnAlpha.formatAmount(rao: totalClaimableRao))
                    .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                    .foregroundColor(themeManager.currentTheme.textColor)
                Text(verbatim: SnAlpha.symbol)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                Spacer()
            }
            Text("Across \(claimableEpochs) finalized epochs")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            Spacer().frame(height: 8)
            UrButton(text: "Claim", action: claim, enabled: claimableEpochs > 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }
}

/// One finalized epoch: points and share of the block; the alpha column
/// only once a wallet is attached.
struct EpochHistoryRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let epoch: AccountEpochInfo
    let claim: SnEpochClaimInfo?
    let showsAlpha: Bool
    let formatAlpha: (Int64) -> String
    let formatShareBps: (Int64) -> String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Epoch \(epoch.epoch)")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                let range = SnAlpha.epochRange(startMillis: epoch.startMillis, endMillis: epoch.endMillis)
                if !range.isEmpty {
                    Text(verbatim: range)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(SnAlpha.formatPoints(epoch.points)) pts")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Text("\(formatShareBps(epoch.shareBps)) of block")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                if showsAlpha {
                    HStack(spacing: 6) {
                        if let claim {
                            Text(verbatim: formatAlpha(claim.amountRao))
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            ClaimStatusPill(status: claim.status)
                        } else {
                            Text(verbatim: "—")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textFaintColor)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 12)
    }
}

/// The not-retroactive sentence as plain body text that opens the protocol site:
/// no link color, no underline; a small outward-arrow glyph after the last word
/// (inline, so it wraps with the sentence) says the tap leaves the app.
struct WalletNotRetroactiveNote: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: {
            if let url = URL(string: "https://ur.xyz") {
                openURL(url)
            }
        }) {
            (
                Text("Connect a wallet to earn SN25α from the next epoch. Earlier epochs are not settled retroactively.")
                    + Text(verbatim: "\u{00A0}")
                    + Text(Image(systemName: "arrow.up.right.square"))
            )
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
    }
}
