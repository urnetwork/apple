//
//  BittensorKeyCard.swift
//  URnetwork
//
//  The payout key's part of the payout card, and the banner above it, drawn from
//  what the SDK's flow says to show (BittensorKeyCardInfo). The words are the
//  plan's (apple/BTEASY.md, Wording), in short form here: the card holds the
//  explanation, so it is read before the one tap, and no screen comes between
//  the tap and the result.
//

import SwiftUI
import URnetworkSdk

/// The words for a failure the flow reports, nil for none.
enum BittensorKeyText {

    static func failure(code: String, message: String) -> String? {
        switch code {
        case "":
            return nil
        case SdkSnErrorCodeChallengeExpired:
            return NetworkConsentFailure.expired.text
        case SdkSnErrorCodeSignatureMismatch:
            return NetworkConsentFailure.signatureMismatch.text
        case SdkSnErrorCodeNetworkOwnerOnly, SdkBittensorLocalKeyFailureNotAllowed:
            return NetworkConsentFailure.ownerOnly.text
        case SdkBittensorLocalKeyFailureGenerate:
            return String(localized: "Couldn't make a key on this device. Try again.")
        case SdkBittensorLocalKeyFailureStore:
            return String(localized: "Couldn't save the key on this device, so nothing was signed. Try again, or save the recovery phrase first.")
        case SdkBittensorLocalKeyFailureStoreUnavailable:
            return String(localized: "Couldn't read this device's secure storage. Unlock your device and try again.")
        case SdkBittensorLocalKeyFailureDelete:
            return String(localized: "Couldn't delete the key from this device. It's still here.")
        case SdkBittensorLocalKeyFailureReplacementNotConfirmed:
            // the card warns first, so this reads only if a warning was skipped
            return String(localized: "This key replaces your payout wallet from the next epoch. Earlier earnings stay on the old wallet.")
        default:
            return message.isEmpty ? String(localized: "Couldn't set up payouts. Try again.") : message
        }
    }
}

/// What the card's key part can do.
struct BittensorKeyCardActions {
    let setUp: () -> Void
    let saveFirst: () -> Void
    let useWallet: () -> Void
    let finishSetup: () -> Void
    let openKeyScreen: () -> Void
    let reload: () -> Void
}

/// The card with no consent in force: the one tap and its two smaller links,
/// or Finish setup for a key already here (the mocks' 1a, 1b and 3i).
struct BittensorKeyNoConsentBody: View {

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo
    let actions: BittensorKeyCardActions

    var body: some View {
        if key.state == SdkBittensorLocalKeyStateSaveLaterNotLinked {
            BittensorKeyCardTitle(text: "Your key is on this device, but payouts aren't set up yet.")
            BittensorKeyCardBody(text: "Setup stopped before signing, so nothing was paid to this key. Finish setup signs the consent with it.")
            BittensorKeyFailureLine(key: key)
            if key.offersFinishSetup {
                Spacer().frame(height: 4)
                UrButton(
                    text: "Finish setup",
                    action: actions.finishSetup,
                    isProcessing: key.busy,
                    accessibilityIdentifier: "earnings.key.finishSetup"
                )
            }
            if key.offersWallet {
                BittensorKeyCardLink(
                    text: "Use a wallet I already have",
                    action: actions.useWallet,
                    accessibilityIdentifier: "earnings.key.useWallet"
                )
                .disabled(key.busy)
            }
        } else if key.state == SdkBittensorLocalKeyStateStoreUnavailable {
            BittensorKeyStoreUnavailable(reload: actions.reload)
        } else {
            BittensorKeyCardTitle(text: "No payout wallet yet. Earnings aren't paid until you set one up.")
            BittensorKeyCardBody(text: "URnetwork is not a wallet. Set up payouts creates a Bittensor key on this device, and your whole network's SN25α is paid to it. Back up its recovery phrase: if you lose this device before saving it, your SN25α can't be reached.")
            BittensorKeyFailureLine(key: key)
            Spacer().frame(height: 4)
            UrButton(
                text: "Set up payouts",
                action: actions.setUp,
                isProcessing: key.busy,
                accessibilityIdentifier: "earnings.key.setUp"
            )
            if key.busy {
                Text("Saving the key on this device and reading it back, then signing.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BittensorKeyCardLink(
                text: "Save the recovery phrase first",
                action: actions.saveFirst,
                accessibilityIdentifier: "earnings.key.saveFirst"
            )
            .disabled(key.busy)
            if key.offersWallet {
                BittensorKeyCardLink(
                    text: "Use a wallet I already have",
                    action: actions.useWallet,
                    accessibilityIdentifier: "earnings.key.useWallet"
                )
                .disabled(key.busy)
            }
        }
    }
}

/// The card with a consent in force, by where its key is (the mocks' 1c, 1i,
/// 1l, 2h, 3a and 3d). The states it doesn't draw keep the wallet card's lines.
struct BittensorKeyActiveBody: View {

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo
    let coldkeySs58: String
    let shortAddress: (String) -> String
    /// the session can choose the payout wallet
    let changesWallet: Bool
    let changeWallet: () -> Void
    let actions: BittensorKeyCardActions

    /// The states this body draws.
    static func draws(_ key: BittensorKeyCardInfo) -> Bool {
        switch key.state {
        case SdkBittensorLocalKeyStateSaveLaterLinked, SdkBittensorLocalKeyStateSavedAndDeleted, SdkBittensorLocalKeyStateElsewhere:
            return true
        default:
            return false
        }
    }

    var body: some View {
        switch key.state {
        case SdkBittensorLocalKeyStateSaveLaterLinked:
            payoutsTitle
            BittensorKeyAddressRow(address: coldkeySs58, shortAddress: shortAddress)
            BittensorKeyCardBody(text: "Every device on your network is paid to this address.")
            if key.keySaved {
                BittensorKeyStatusRow(dot: .urGreen, text: "Key on this device, recovery phrase saved")
                BittensorKeyCardLink(text: "View key", action: actions.openKeyScreen, accessibilityIdentifier: "earnings.key.show")
            } else {
                BittensorKeyStatusRow(dot: .urYellow, text: "Key on this device, not backed up yet")
                UrButton(
                    text: "Back up your key",
                    action: actions.openKeyScreen,
                    style: .secondary,
                    accessibilityIdentifier: "earnings.key.backUp"
                )
            }
            BittensorKeyFailureLine(key: key)
            if changesWallet {
                BittensorKeyCardLink(text: "Change wallet", action: changeWallet, accessibilityIdentifier: "earnings.key.changeWallet")
            }
        case SdkBittensorLocalKeyStateSavedAndDeleted:
            payoutsTitle
            BittensorKeyAddressRow(address: coldkeySs58, shortAddress: shortAddress)
            BittensorKeyCardBody(text: "Every device on your network is paid to this address.")
            BittensorKeyStatusRow(systemImage: "key.slash", text: "This app no longer has the key")
            BittensorKeyCardBody(text: "Claims keep working. To transfer or convert your SN25α, or to claim a Top 200 spot, use a Bittensor wallet holding your recovery phrase.")
            BittensorKeyFailureLine(key: key)
            changeWalletButton
        default:
            // elsewhere: a wallet, or a key on another device; nothing here tells them apart
            BittensorKeyCardTitle(verbatim: String(localized: "Earnings are paid to \(shortAddress(coldkeySs58))"))
            BittensorKeyStatusRow(systemImage: "key", text: "This key is on another device or in your wallet.")
            BittensorKeyCardBody(text: "Its recovery phrase can't be shown here.")
            BittensorKeyFailureLine(key: key)
            changeWalletButton
        }
    }

    @ViewBuilder
    private var payoutsTitle: some View {
        if key.payoutsStartNextEpoch {
            BittensorKeyCardTitle(text: "Payouts start next epoch")
        } else {
            BittensorKeyCardTitle(text: "Payouts are on")
        }
    }

    @ViewBuilder
    private var changeWalletButton: some View {
        if changesWallet {
            Spacer().frame(height: 4)
            UrButton(text: "Change wallet", action: changeWallet, style: .secondary, accessibilityIdentifier: "earnings.key.changeWallet")
            Text("A new wallet takes effect from the next epoch.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the card adds under "Earnings are paid to" in the states the active
/// body leaves to the wallet card: a key here the consent doesn't pay, and a
/// store that can't answer.
struct BittensorKeyActiveLines: View {

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo
    let actions: BittensorKeyCardActions

    var body: some View {
        switch key.state {
        case SdkBittensorLocalKeyStateSaveLaterNotLinked:
            Text("The key on this device isn't receiving payouts.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            if key.offersFinishSetup {
                UrButton(
                    text: "Finish setup",
                    action: actions.finishSetup,
                    style: .secondary,
                    isProcessing: key.busy,
                    accessibilityIdentifier: "earnings.key.finishSetup"
                )
            }
            if key.offersKeyScreen {
                BittensorKeyCardLink(
                    text: key.keySaved ? "View key" : "Back up your key",
                    action: actions.openKeyScreen,
                    accessibilityIdentifier: "earnings.key.backUp"
                )
            }
        case SdkBittensorLocalKeyStateStoreUnavailable:
            BittensorKeyStoreUnavailable(reload: actions.reload)
        default:
            EmptyView()
        }
        BittensorKeyFailureLine(key: key)
    }
}

/// The card's title line.
struct BittensorKeyCardTitle: View {

    @EnvironmentObject var themeManager: ThemeManager

    private let text: Text

    init(text: LocalizedStringKey) {
        self.text = Text(text)
    }

    init(verbatim: String) {
        self.text = Text(verbatim: verbatim)
    }

    var body: some View {
        text
            .font(themeManager.currentTheme.bodyFont.weight(.semibold))
            .foregroundColor(themeManager.currentTheme.textColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BittensorKeyCardBody: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The address the consent pays, with Copy. Not a secret.
struct BittensorKeyAddressRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    let address: String
    let shortAddress: (String) -> String

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(themeManager.currentTheme.accentColor)
                .accessibilityHidden(true)
            Text(verbatim: shortAddress(address))
                .font(.system(.body, design: .monospaced))
                .foregroundColor(themeManager.currentTheme.textColor)
            Button(action: {
                EarningsClipboard.copy(address)
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
            .accessibilityLabel(Text("Copy"))
            Spacer()
        }
        .accessibilityIdentifier("earnings.key.address")
    }
}

/// Where the key is, beside a colored dot or an icon.
struct BittensorKeyStatusRow: View {

    @EnvironmentObject var themeManager: ThemeManager

    var dot: Color? = nil
    var systemImage: String = ""
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("earnings.key.status")
    }
}

struct BittensorKeyStoreUnavailable: View {

    @EnvironmentObject var themeManager: ThemeManager

    let reload: () -> Void

    var body: some View {
        Text("Couldn't read this device's secure storage. Unlock your device and try again.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
        BittensorKeyCardLink(text: "Retry", action: reload, accessibilityIdentifier: "earnings.key.reload")
    }
}

/// The owner's disclaimer (apple/BTEASY.md, Wording), in plain view on every
/// screen of the easy flows: the whole text where the key is in this app's
/// secure storage, its last sentence alone where it isn't, nothing elsewhere.
/// The sdk says which (BittensorFundsDisclaimer*), so every app shows the same.
struct BittensorFundsDisclaimerText: View {

    @EnvironmentObject var themeManager: ThemeManager

    let disclaimer: String
    /// in its own box, at the foot of a screen of its own
    var boxed = false

    var body: some View {
        if let text = Self.text(disclaimer) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(boxed ? 12 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(boxed ? themeManager.currentTheme.tintedBackgroundBase : Color.clear)
            .cornerRadius(boxed ? 8 : 0)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("earnings.key.fundsDisclaimer")
        }
    }

    /// The words for the sdk's disclaimer id, nil for none.
    static func text(_ disclaimer: String) -> String? {
        switch disclaimer {
        case SdkBittensorFundsDisclaimerFull:
            return String(localized: "This key is stored locally in the app secure storage. It is never shared with URnetwork. URnetwork does not touch and is not responsible for any user funds.")
        case SdkBittensorFundsDisclaimerFundsOnly:
            return String(localized: "URnetwork does not touch and is not responsible for any user funds.")
        default:
            return nil
        }
    }
}

struct BittensorKeyFailureLine: View {

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo

    var body: some View {
        if let text = BittensorKeyText.failure(code: key.failureCode, message: key.failureMessage) {
            Text(verbatim: text)
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.dangerColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BittensorKeyCardLink: View {

    @EnvironmentObject var themeManager: ThemeManager

    let text: LocalizedStringKey
    let action: () -> Void
    var accessibilityIdentifier: String = ""

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                .foregroundColor(.urLightBlue)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// While the key's phrase isn't known to be saved: stays until it is, and
/// doesn't go away for anything else.
struct BittensorKeyBackupBanner: View {

    @EnvironmentObject var themeManager: ThemeManager

    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.urYellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Back up your key")
                        .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                        .foregroundColor(themeManager.currentTheme.textColor)
                    Text("If you lose this device before saving your recovery phrase, your SN25α can't be reached.")
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .accessibilityHidden(true)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.urYellow.opacity(0.6), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("earnings.key.banner")
    }
}
