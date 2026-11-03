//
//  ClaimRelaySheet.swift
//  URnetwork
//
//  Claims through URnetwork's claim relay (apple/BTEASY.md, Claim relay, and
//  the approved mocks' flow 4). URnetwork claims every consented network's
//  settlement v2 balance and pays the gas: by itself once a balance is worth
//  the automatic threshold, and on Claim now, at most once in a period for
//  each coldkey. Small amounts wait and say why. The device's own claim with
//  its gas key stays as the fallback. The sdk decides all of it
//  (SnClaimStatus); these views only word it.
//

import SwiftUI
import URnetworkSdk

/// Who claims, why the balance is still pending, and on the tile Claim now
/// with its limit, or the device's own claim while the relay isn't claiming.
/// Once URnetwork has claimed it all (sdk ShowsClaimed), the tile says so, and
/// opens the claim sheet, which shows the claim's transaction.
struct SnClaimRelaySection: View {

    @EnvironmentObject var themeManager: ThemeManager

    let status: SnClaimStatusInfo
    /// opens the claim sheet
    let claimNow: () -> Void
    let selfClaim: () -> Void
    /// in the claim sheet, which has its own Claim now
    let inSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.relayClaims {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.urLightBlue)
                        .accessibilityHidden(true)
                    Text("URnetwork claims this for you")
                        .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                .accessibilityIdentifier("earnings.claimRelay.forYou")
            }
            if 0 < status.claimableRao {
                HStack(alignment: .top, spacing: 8) {
                    SnClaimRelayPill(text: "Pending")
                    SnClaimRelayReason(status: status)
                }
            }
            if !inSheet {
                if status.showsClaimed {
                    // nothing is left to claim: the claimed state, which opens the
                    // claim sheet with its transaction
                    Button(action: claimNow) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.urGreen)
                                .accessibilityHidden(true)
                            SnClaimRelayClaimedText(status: status)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("earnings.claimRelay.claimed")
                    SnClaimRelayAgainOn(status: status)
                } else if status.relayClaims {
                    UrButton(
                        text: "Claim now",
                        action: claimNow,
                        style: .secondary,
                        enabled: status.claimNowAvailable,
                        accessibilityIdentifier: "earnings.claimRelay.claimNow"
                    )
                    SnClaimNowNote(status: status, eachColdkey: false)
                } else {
                    UrButton(text: "Claim now", action: claimNow, style: .secondary, enabled: false)
                    note("Claim now waits until claims are running again. To claim right away, pay the gas yourself:")
                    if status.selfClaimAvailable {
                        BittensorKeyCardLink(text: "Claim it yourself with your gas key", action: selfClaim, accessibilityIdentifier: "earnings.claimRelay.selfClaim")
                    }
                }
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Why a balance is still pending (sdk SnClaimReason*).
struct SnClaimRelayReason: View {

    @EnvironmentObject var themeManager: ThemeManager

    let status: SnClaimStatusInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch status.reason {
            case SdkSnClaimReasonUnderThreshold:
                title("Below the automatic threshold.")
                if 0 < status.automaticThresholdTaoRao {
                    if 0 < status.automaticThresholdRao {
                        detail("It's claimed for you once it's worth about \(SnAlpha.formatTaoAmount(rao: status.automaticThresholdTaoRao)) TAO, about \(SnAlpha.formatApprox(rao: status.automaticThresholdRao)) SN25α at today's price. Waiting costs nothing: this credit never expires.")
                    } else {
                        detail("It's claimed for you once it's worth about \(SnAlpha.formatTaoAmount(rao: status.automaticThresholdTaoRao)) TAO. Waiting costs nothing: this credit never expires.")
                    }
                }
            case SdkSnClaimReasonQueued:
                title("URnetwork claims this soon.")
            case SdkSnClaimReasonCapReached:
                title("Today's claim budget is used up, so this waits for the next day. Nothing is lost: this credit never expires.")
            case SdkSnClaimReasonRefused:
                title("The last claim didn't go through. URnetwork tries again later.")
            case SdkSnClaimReasonRelayNotRunning:
                title("Automatic claims aren't running right now.")
                detail("Your SN25α waits in the vault, and this credit never expires.")
            case SdkSnClaimReasonRelayPaused:
                title("URnetwork has paused claims for now.")
                detail("Your SN25α waits in the vault, and this credit never expires.")
            default:
                EmptyView()
            }
        }
    }

    private func title(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Under Claim now: who pays and how often, or why it can't be tapped now.
struct SnClaimNowNote: View {

    @EnvironmentObject var themeManager: ThemeManager

    let status: SnClaimStatusInfo
    /// the sheet's wording, per coldkey
    let eachColdkey: Bool

    var body: some View {
        Group {
            if status.claimNowAvailable {
                if 0 < status.claimNowPeriodDays {
                    if eachColdkey {
                        Text("Paid by URnetwork, once every \(status.claimNowPeriodDays) days for each coldkey.")
                    } else {
                        Text("Claim now is paid by URnetwork, once every \(status.claimNowPeriodDays) days.")
                    }
                }
            } else {
                switch status.claimNowReason {
                case SdkSnClaimNowReasonUnderFloor:
                    if 0 < status.transferFloorTaoRao {
                        Text("Claim now needs a balance worth at least \(SnAlpha.formatTaoAmount(rao: status.transferFloorTaoRao)) TAO.")
                    }
                case SdkSnClaimNowReasonRequested:
                    Text("Claim now is queued. URnetwork sends it first, within today's budget.")
                case SdkSnClaimNowReasonLimit:
                    if 0 < status.claimNowNextAtMillis {
                        Text("Claim now is available again on \(SnClaimNowNote.date(status.claimNowNextAtMillis)).")
                    }
                default:
                    EmptyView()
                }
            }
        }
        .font(themeManager.currentTheme.secondaryBodyFont)
        .foregroundColor(themeManager.currentTheme.textMutedColor)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func date(_ millis: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1000).formatted(date: .abbreviated, time: .omitted)
    }
}

struct SnClaimRelayPill: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
            .foregroundColor(themeManager.currentTheme.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(themeManager.currentTheme.textMutedColor.opacity(0.2)))
    }
}

/// The claimed state's sentence (the mocks' 4d): what URnetwork's claim paid
/// and the key it is on, or "Claimed" without an amount or a key to name.
struct SnClaimRelayClaimedText: View {

    @EnvironmentObject var themeManager: ThemeManager

    let status: SnClaimStatusInfo

    var body: some View {
        Group {
            if 0 < status.claimAmountRao, !status.coldkeySs58.isEmpty {
                Text("Claimed by URnetwork. \(SnAlpha.formatAmount(rao: status.claimAmountRao)) SN25α is on your key, \(SnAlpha.shortSs58(status.coldkeySs58)).")
            } else {
                Text("Claimed")
            }
        }
        .font(themeManager.currentTheme.secondaryBodyFont)
        .foregroundColor(themeManager.currentTheme.textColor)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The claimed state in the claim sheet: the sentence and the claim's
/// transaction on the explorer (sdk ClaimTxUrl).
struct SnClaimRelayClaimed: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    let status: SnClaimStatusInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.urGreen)
                    .accessibilityHidden(true)
                SnClaimRelayClaimedText(status: status)
            }
            if !status.claimTxUrl.isEmpty, let url = URL(string: status.claimTxUrl) {
                Button(action: {
                    openURL(url)
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
                .accessibilityIdentifier("earnings.claimRelay.transaction")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.urGreen.opacity(0.6), lineWidth: 1)
        )
        .accessibilityIdentifier("earnings.claimRelay.claimed")
    }
}

/// When Claim now works again after URnetwork paid a tapped claim (sdk
/// ClaimNowNextAtMillis); nothing while no limit holds.
struct SnClaimRelayAgainOn: View {

    @EnvironmentObject var themeManager: ThemeManager

    let status: SnClaimStatusInfo

    var body: some View {
        if 0 < status.claimNowNextAtMillis {
            Text("Claim now is available again on \(SnClaimNowNote.date(status.claimNowNextAtMillis)).")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Claim now, from the settlement v2 tile: the balance, where it lands, why
/// it's still pending, and Claim now or why it can't act, with the device's own
/// claim as the fallback.
struct ClaimRelaySheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject var viewModel: EarningsViewModel
    /// the disclaimer's last sentence: claims land on the coldkey, wherever its key is
    let fundsDisclaimer: String
    let selfClaim: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    UrLabel(text: "Settlement v2")
                    Text("Claim SN25α")
                        .font(themeManager.currentTheme.toolbarTitleFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                }
                if let status = viewModel.claimStatus, !status.unavailable {
                    content(status)
                } else {
                    Text("Unavailable")
                        .font(themeManager.currentTheme.titleCondensedFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                BittensorFundsDisclaimerText(disclaimer: fundsDisclaimer, boxed: true)
                // the claimed state ends with its own Done
                if viewModel.claimStatus?.showsClaimed != true {
                    Button(action: dismiss) {
                        Text("Close")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("earnings.claimRelay.close")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(themeManager.currentTheme.backgroundColor)
    }

    @ViewBuilder
    private func content(_ status: SnClaimStatusInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            UrLabel(text: "Claimable")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: SnAlpha.formatAmount(rao: status.claimableRao))
                    .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                    .foregroundColor(themeManager.currentTheme.textColor)
                Text(verbatim: SnAlpha.symbol)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                Spacer()
            }
        }
        if !status.coldkeySs58.isEmpty {
            Text("URnetwork claims this for you. It pays the gas, and your SN25α lands on \(SnAlpha.shortSs58(status.coldkeySs58)).")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        SnClaimRelaySection(status: status, claimNow: {}, selfClaim: selfClaim, inSheet: true)

        if status.showsClaimed {
            // the claimed state (the mocks' 4d): URnetwork claimed it all and paid
            // the gas; a tap that queued it has landed
            SnClaimRelayClaimed(status: status)
            UrButton(text: "Done", action: dismiss, accessibilityIdentifier: "earnings.claimRelay.done")
            SnClaimRelayAgainOn(status: status)
        } else {
            claimNowContent(status)
        }
        if status.selfClaimAvailable {
            BittensorKeyCardLink(text: "Claim it yourself with your gas key", action: selfClaim, accessibilityIdentifier: "earnings.claimRelay.sheetSelfClaim")
        }
    }

    /// Claim now, its answer, or why it waits.
    @ViewBuilder
    private func claimNowContent(_ status: SnClaimStatusInfo) -> some View {
        switch viewModel.claimNowOutcome {
        case .requested:
            Text("Claim now is queued. URnetwork sends it first, within today's budget.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
            UrButton(text: "Queued", action: {}, enabled: false, accessibilityIdentifier: "earnings.claimRelay.queued")
        case .refused(let reason, let nextAtMillis):
            SnClaimNowNote(
                status: SnClaimStatusInfo(claimNowReason: reason, claimNowNextAtMillis: nextAtMillis, transferFloorTaoRao: status.transferFloorTaoRao),
                eachColdkey: true
            )
        case .failed(let message):
            Text(verbatim: message)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            if status.relayClaims {
                UrButton(
                    text: "Claim now",
                    action: {
                        Task {
                            await viewModel.claimNow()
                        }
                    },
                    enabled: status.claimNowAvailable,
                    isProcessing: viewModel.isClaimingNow,
                    accessibilityIdentifier: "earnings.claimRelay.sheetClaimNow"
                )
                SnClaimNowNote(status: status, eachColdkey: true)
            } else {
                Text("Claim now waits until claims are running again. To claim right away, pay the gas yourself:")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
