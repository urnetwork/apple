//
//  EarningsTiles.swift
//  URnetwork
//
//  The tiles of the Earnings screen: the Top 200 head
//  spot, the Bittensor wallet block with its wallet options, the unclaimed
//  alpha tile, the settlement v2 tile, the network payout consent card, the
//  SN payout line of the points card and the epoch history rows.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The head-miner spot. Eligible and not yet bound: the gold call to claim
/// the spot on ur.io. Bound: the UID and rank, with the eviction warning
/// when the score sits close to the floor. Both carry Sign fleet binding,
/// where this device signs the binding the fleet operator builds on ur.io
/// (bindings renew per epoch window and new devices join the fleet).
struct Top200Tile: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    let head: SnHeadInfo
    /// opens Sign fleet binding
    let sign: () -> Void

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
            Button(action: sign) {
                Text("Sign fleet binding")
                    .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                    .foregroundColor(introProGoldLight)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(Capsule().stroke(introProGoldLight, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("earnings.top200.sign")
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
            Spacer().frame(height: 4)
            UrButton(
                text: "Sign fleet binding",
                action: sign,
                style: .secondary,
                isFullWidth: false,
                accessibilityIdentifier: "earnings.top200.sign"
            )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }
}

/// The Bittensor wallet block: the connect call when none is attached, the
/// coldkey and the settlement note once it is. Its wallet options connect the
/// Solana wallet USDC payouts go to until the migration to Bittensor is
/// complete: next to the connect button, or at the trailing end of the header
/// once a coldkey is attached.
struct BittensorWalletCard: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    let wallet: SnWalletInfo?
    let shortAddress: (String) -> String
    let connect: () -> Void
    /// the final USDC payout waiting while there is no Solana payout wallet,
    /// or nil
    let pendingUsd: String?
    let connectSolana: () -> Void
    /// the wallet read failed with no cached wallet: whether one is connected
    /// is unknown, so no connect offer
    var loadFailed: Bool = false
    var retry: () -> Void = {}

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let wallet {
                HStack {
                    UrLabel(text: "Bittensor wallet")
                    Spacer()
                    WalletOverflowMenu(style: .plain) {
                        connectSolanaItem
                    }
                }
                pendingLine
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
            } else if loadFailed {
                UrLabel(text: "Bittensor wallet")
                SectionLoadFailedView(retry: retry)
            } else {
                UrLabel(text: "Bittensor wallet")
                WalletNotRetroactiveNote()
                Spacer().frame(height: 4)
                pendingLine
                HStack(spacing: 8) {
                    UrButton(text: "Connect Bittensor wallet", action: connect)
                    WalletOverflowMenu(style: .bordered) {
                        connectSolanaItem
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    /// "Final USDC payout: 3.87 USDC waiting", while the last USDC payout is
    /// held for want of a Solana wallet
    @ViewBuilder
    private var pendingLine: some View {
        if let pendingUsd {
            Text(verbatim: UsdcFormat.finalPayoutWaiting(pendingUsd))
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
        }
    }

    private var connectSolanaItem: some View {
        Button(action: connectSolana) {
            Label {
                Text("Connect Solana wallet")
            } icon: {
                SolanaMenuIcon.image
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("acceptance.earnings.connectSolana")
    }
}

/// The three-dot wallet options: bordered at the height of the button beside
/// it, or plain at the trailing end of a wallet card's header.
struct WalletOverflowMenu<Content: View>: View {

    enum Style {
        case bordered
        case plain
    }

    @EnvironmentObject var themeManager: ThemeManager

    let style: Style
    var accessibilityIdentifier: String = "acceptance.earnings.walletOptions"
    @ViewBuilder let items: () -> Content

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: style == .bordered ? 16 : 13))
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: side, height: side)
        .overlay(border)
        .accessibilityLabel(Text("Wallet options"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var side: CGFloat {
        style == .bordered ? 48 : 28
    }

    @ViewBuilder
    private var border: some View {
        if style == .bordered {
            RoundedRectangle(cornerRadius: 8)
                .stroke(themeManager.currentTheme.borderStrongColor, lineWidth: 1)
        }
    }
}

/// The Solana logomark sized for a menu item. Menus drop frame modifiers and
/// show an asset image at its own size (the logomark is 313×281 pt), so the
/// logo is drawn into a small template image once.
private enum SolanaMenuIcon {

    static let image: Image = {
        let side: CGFloat = 16
        #if canImport(UIKit)
        guard let logo = UIImage(named: "solana.logo") else {
            return Image("solana.logo")
        }
        let size = CGSize(width: side, height: side)
        let sized = UIGraphicsImageRenderer(size: size).image { _ in
            logo.draw(in: SolanaMenuIcon.aspectFit(logo.size, in: size))
        }
        return Image(uiImage: sized.withRenderingMode(.alwaysTemplate))
        #elseif canImport(AppKit)
        guard let logo = NSImage(named: "solana.logo") else {
            return Image("solana.logo")
        }
        let size = NSSize(width: side, height: side)
        let sized = NSImage(size: size, flipped: false) { _ in
            logo.draw(in: SolanaMenuIcon.aspectFit(logo.size, in: size))
            return true
        }
        sized.isTemplate = true
        return Image(nsImage: sized)
        #endif
    }()

    private static func aspectFit(_ content: CGSize, in bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let fitted = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
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

/// Settlement v2, beside the v1 unclaimed tile: the coldkey's balance in
/// each operator pool's STSettlementVault2, which never expires. Claimable
/// is the headline, then what was earned (the finalized cumulative) and
/// paid, and what a committed root adds while it awaits finalization. A
/// ledger that cannot be read says "Unavailable", never 0. Claim opens the
/// v2 claim dialog once v2 claims are configured.
struct SnLedgerTile: View {

    @EnvironmentObject var themeManager: ThemeManager

    let presentation: SnLedgerTilePresentation
    let claim: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            UrLabel(text: "Settlement v2")
            switch presentation.balances {
            case .unavailable:
                Text("Unavailable")
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            case .accounts(let accounts):
                ForEach(accounts) { account in
                    accountBalances(account)
                }
            }
            if presentation.showsClaim {
                Spacer().frame(height: 8)
                UrButton(text: "Claim", action: claim, enabled: presentation.claimEnabled)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    @ViewBuilder
    private func accountBalances(_ account: SnLedgerAccountInfo) -> some View {
        if presentation.showsPools {
            Text("Pool \(account.noId)")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .padding(.top, 8)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: SnAlpha.formatAmount(rao: account.claimableRao))
                .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                .foregroundColor(themeManager.currentTheme.textColor)
            Text(verbatim: SnAlpha.symbol)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            Spacer()
        }
        Text("Claimable")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
        Spacer().frame(height: 8)
        HStack {
            column("Earned", account.finalizedRao)
            Spacer()
            column("Paid", account.paidRao)
            Spacer()
        }
        if let pendingRao = account.pendingIncreaseRao {
            Text("Pending: +\(SnAlpha.format(rao: pendingRao)), awaiting finalization")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .padding(.top, 4)
        }
    }

    private func column(_ label: LocalizedStringKey, _ rao: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            UrLabel(text: label)
            Text(verbatim: SnAlpha.formatAmount(rao: rao))
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundColor(themeManager.currentTheme.textColor)
        }
    }
}

/// The network payout consent, beside the settlement v2 tile: the coldkey
/// every provider client of the network is paid to, or that there is none,
/// so earnings are not paid. Sign with wallet and Change wallet open the
/// consent sheet, and only a session with the network credential is offered
/// them: any other is told only the owner can. A consent, the first or a new
/// one, takes effect from the next epoch. A status that could not be read is
/// not "no consent".
struct NetworkConsentCard: View {

    @EnvironmentObject var themeManager: ThemeManager

    let status: NetworkConsentFlow.Status
    let hasNetworkCredential: Bool
    let shortAddress: (String) -> String
    let sign: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UrLabel(text: "Payout consent")
            switch status {
            case .loading:
                ProgressView()
            case .unavailable:
                SectionLoadFailedView(retry: retry)
            case .noConsent:
                Text("No payout wallet yet. Earnings aren't paid until you sign.")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                if hasNetworkCredential {
                    Text("Sign once with your Bittensor wallet so this network's earnings are paid to it.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer().frame(height: 4)
                    UrButton(text: "Sign with wallet", action: sign)
                } else {
                    ownerOnly
                }
            case .active(let coldkeySs58):
                Text("Earnings are paid to \(shortAddress(coldkeySs58))")
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                if hasNetworkCredential {
                    Spacer().frame(height: 4)
                    UrButton(text: "Change wallet", action: sign, style: .secondary)
                } else {
                    ownerOnly
                }
                Text("A new wallet takes effect from the next epoch.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    /// a session without the network credential cannot sign
    private var ownerOnly: some View {
        Text("Only the network owner can choose the payout wallet.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// How and when the provider is paid on the UR subnet, at the foot of the
/// points card. With a coldkey: the explanation, the current epoch's times
/// when known, and Claim while something is claimable (the claim sheet; the
/// app never claims by itself). Without one: the prompt to set it, with the
/// action that opens the coldkey flow.
struct SnPayoutLineView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let line: SnPayoutLine
    let claim: () -> Void
    let setColdkey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch line {
            case .setColdkey:
                Text("Set your Bittensor coldkey to get paid")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                Button(action: setColdkey) {
                    Text("Set coldkey")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("acceptance.earnings.setColdkey")
            case .schedule(let times, let claimable):
                Text("Earnings settle every epoch and are paid in SN25α to your Bittensor coldkey when you claim them.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                if let times {
                    Text("This epoch ends \(times.epochEnd). Claim your share from \(times.claimOpen) until \(times.expiry).")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                if claimable {
                    Spacer().frame(height: 4)
                    UrButton(text: "Claim", action: claim)
                        .accessibilityIdentifier("acceptance.earnings.payoutClaim")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("acceptance.earnings.payoutLine")
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

/// The not-retroactive sentence as plain body text (not tappable), followed by
/// a small "Learn more" link in the pink accent with an outward-arrow glyph
/// that opens the protocol site. The link rides inline after the sentence, so
/// it shares the line when it fits and wraps to the next otherwise.
struct WalletNotRetroactiveNote: View {
    @EnvironmentObject var themeManager: ThemeManager

    private var learnMore: Text {
        var link = AttributedString(String(localized: "Learn more"))
        link.link = URL(string: "https://ur.xyz")
        link.foregroundColor = .urPink
        return Text(link)
    }

    var body: some View {
        (
            Text("Connect a wallet to earn SN25α from the next epoch. Earlier epochs are not settled retroactively.")
                + Text(verbatim: "\u{00A0}")
                + learnMore
                + Text(verbatim: "\u{00A0}")
                + Text(Image(systemName: "arrow.up.right.square")).foregroundColor(.urPink)
        )
        .font(themeManager.currentTheme.secondaryBodyFont)
        .foregroundColor(themeManager.currentTheme.textMutedColor)
        .tint(.urPink)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
