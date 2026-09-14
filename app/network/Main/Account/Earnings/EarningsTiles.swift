//
//  EarningsTiles.swift
//  URnetwork
//
//  The tiles of the Earnings screen: the Top 200 head
//  spot, the Bittensor wallet block with its wallet options, the unclaimed
//  alpha tile and the epoch history rows.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    /// the USDC waiting while there is no Solana payout wallet, or nil
    let pendingUsd: String?
    let connectSolana: () -> Void

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

    /// "3.87 USDC waiting", while payouts are held for want of a Solana wallet
    @ViewBuilder
    private var pendingLine: some View {
        if let pendingUsd {
            Text("\(pendingUsd) USDC waiting")
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
