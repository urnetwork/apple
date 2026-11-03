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
            return String(localized: "Couldn't read this device's keychain. Unlock your device and try again.")
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
/// or Finish setup for a key already here.
struct BittensorKeyNoConsentBody: View {

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo
    let actions: BittensorKeyCardActions

    var body: some View {
        if key.state == SdkBittensorLocalKeyStateSaveLaterNotLinked {
            Text("Your key is on this device, but payouts aren't set up yet.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
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
            BittensorKeyBackUpLink(key: key, open: actions.openKeyScreen, prominence: .secondary)
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
            Text("No payout wallet yet. Earnings aren't paid until you set one up.")
                .font(themeManager.currentTheme.bodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("URnetwork creates a Bittensor key on this device and pays every miner on your network to it, from the next epoch.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("URnetwork is not a wallet. To transfer or use your SN25α, you enter the key's recovery phrase into a Bittensor wallet or btcli. If you lose this device before saving it, your SN25α can't be reached.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            BittensorKeyFailureLine(key: key)
            Spacer().frame(height: 4)
            UrButton(
                text: "Set up payouts",
                action: actions.setUp,
                isProcessing: key.busy,
                accessibilityIdentifier: "earnings.key.setUp"
            )
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

/// What the card adds under "Earnings are paid to", by where the key is.
struct BittensorKeyActiveLines: View {

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo
    let actions: BittensorKeyCardActions

    var body: some View {
        if key.payoutsStartNextEpoch {
            Text("Payouts start next epoch")
                .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                .foregroundColor(themeManager.currentTheme.textColor)
        }
        switch key.state {
        case SdkBittensorLocalKeyStateSaveLaterLinked:
            BittensorKeyBackUpLink(key: key, open: actions.openKeyScreen)
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
            BittensorKeyBackUpLink(key: key, open: actions.openKeyScreen, prominence: .link)
        case SdkBittensorLocalKeyStateSavedAndDeleted:
            Text("This app no longer has the key")
                .font(themeManager.currentTheme.secondaryBodyFont.weight(.semibold))
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your earnings keep going to this address. To transfer or use your SN25α, enter your recovery phrase into a Bittensor wallet such as Talisman or Nova, or into btcli.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        case SdkBittensorLocalKeyStateElsewhere:
            Text("This key is on another device or in your wallet.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
        case SdkBittensorLocalKeyStateStoreUnavailable:
            BittensorKeyStoreUnavailable(reload: actions.reload)
        default:
            EmptyView()
        }
        BittensorKeyFailureLine(key: key)
    }
}

/// A key the consent doesn't pay holds its own earlier earnings, so it stays
/// reachable: Back up your key while unsaved, and the screen after that.
struct BittensorKeyBackUpLink: View {

    /// How loud Back up your key is beside the card's other actions.
    enum Prominence {
        /// the card's main action
        case primary
        /// under another main action
        case secondary
        /// beside two buttons already
        case link
    }

    @EnvironmentObject var themeManager: ThemeManager

    let key: BittensorKeyCardInfo
    let open: () -> Void
    var prominence: Prominence = .primary

    var body: some View {
        if key.keySaved {
            Text("Your recovery phrase is saved, and the key stays on this device.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
            BittensorKeyCardLink(text: "Show key", action: open, accessibilityIdentifier: "earnings.key.show")
        } else if key.offersKeyScreen {
            switch prominence {
            case .primary, .secondary:
                UrButton(
                    text: "Back up your key",
                    action: open,
                    style: prominence == .primary ? .primary : .secondary,
                    accessibilityIdentifier: "earnings.key.backUp"
                )
            case .link:
                BittensorKeyCardLink(text: "Back up your key", action: open, accessibilityIdentifier: "earnings.key.backUp")
            }
        }
    }
}

/// Creating a key on a network whose consent pays another address replaces
/// that wallet, so it is a small link, and the warning comes before it acts.
struct BittensorKeyCreateHereLink: View {

    let key: BittensorKeyCardInfo
    let actions: BittensorKeyCardActions

    var body: some View {
        if key.offersSetUp {
            BittensorKeyCardLink(
                text: "Create a key on this device",
                action: actions.setUp,
                accessibilityIdentifier: "earnings.key.createHere"
            )
            .disabled(key.busy)
        }
    }
}

struct BittensorKeyStoreUnavailable: View {

    @EnvironmentObject var themeManager: ThemeManager

    let reload: () -> Void

    var body: some View {
        Text("Couldn't read this device's keychain. Unlock your device and try again.")
            .font(themeManager.currentTheme.secondaryBodyFont)
            .foregroundColor(themeManager.currentTheme.textMutedColor)
            .fixedSize(horizontal: false, vertical: true)
        BittensorKeyCardLink(text: "Retry", action: reload, accessibilityIdentifier: "earnings.key.reload")
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
