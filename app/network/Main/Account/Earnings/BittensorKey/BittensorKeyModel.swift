//
//  BittensorKeyModel.swift
//  URnetwork
//
//  The Earnings screen's side of the SDK's payout key flow: it mirrors the card
//  and the Key screen onto the main actor, and does for the flow what only this
//  platform can do: device authentication, the pasteboard, the warning before a
//  replacement, and the local notification. Every decision about the key is the
//  flow's (sdk BittensorLocalKeyFlow).
//
//  A stored key's words are read only after device authentication, and they
//  leave `words` as soon as the flow hides them. Nothing here prints or logs.
//

import Foundation
import URnetworkSdk

@MainActor
final class BittensorKeyModel: ObservableObject {

    /// What the warning before a replacement goes on to do.
    enum PendingReplacement: Equatable {
        /// a new key: Set up payouts or Save the recovery phrase first
        case makeKey
        /// the key on this device, which the consent doesn't pay
        case finishSetup
    }

    @Published private(set) var card: BittensorKeyCardInfo
    @Published private(set) var screen: BittensorKeyScreenInfo
    /// the words on the screen, empty while hidden
    @Published private(set) var words: [String] = []
    /// the warning that a new key replaces the payout wallet
    @Published var pendingReplacement: PendingReplacement?
    /// Copy was tapped: the short "Copied" state
    @Published private(set) var copied = false
    /// iOS said a screenshot was taken while the words showed
    @Published private(set) var screenshotWarning = false

    let flow: BittensorKeyFlowing
    private let authenticator: BittensorDeviceAuthenticating
    private let pasteboard: BittensorKeyPasteboarding
    private let reminderNotice: BittensorKeyReminderPosting
    private var observedLinkGeneration: Int64 = 0
    private var copiedResetTask: Task<Void, Never>?

    /// a consent went through this flow: read the consent and earnings again
    var onLinked: () -> Void = {}

    init(
        flow: BittensorKeyFlowing,
        authenticator: BittensorDeviceAuthenticating = BittensorDeviceAuthenticator(),
        pasteboard: BittensorKeyPasteboarding = BittensorKeyPasteboard.shared,
        reminderNotice: BittensorKeyReminderPosting = BittensorKeyReminderNotice()
    ) {
        self.flow = flow
        self.authenticator = authenticator
        self.pasteboard = pasteboard
        self.reminderNotice = reminderNotice
        card = flow.card
        screen = flow.screen
        observedLinkGeneration = card.linkGeneration
        flow.onChange { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        flow.close()
    }

    /// Mirrors the flow. A finished screen closes itself.
    func refresh() {
        let card = flow.card
        var screen = flow.screen
        if screen.done && screen.open {
            flow.closeScreen()
            screen = flow.screen
        }
        // saved or deleted since the last look: a notification still on its way
        // would remind of nothing
        let reminderEnded = self.card.backupReminder && !card.backupReminder
        if self.card != card {
            self.card = card
        }
        if reminderEnded {
            reminderNotice.apply(
                flow.reminder(currentEpoch: 0, claimOpenMillis: 0, epochBlocks: 0, claimable: false),
                flow: flow
            )
        }
        if self.screen != screen {
            self.screen = screen
        }
        let words = screen.revealed ? flow.revealedWords : []
        if self.words != words {
            self.words = words
        }
        if !screen.open {
            screenshotWarning = false
        }
        if card.linkGeneration != observedLinkGeneration {
            observedLinkGeneration = card.linkGeneration
            onLinked()
        }
    }

    // MARK: what the rest of Earnings read

    func consentRead(_ status: NetworkConsentFlow.Status, fromEpoch: Int64) {
        switch status {
        case .loading:
            break
        case .unavailable:
            flow.setConsentUnavailable()
        case .noConsent:
            flow.setConsent(active: false, coldkeySs58: "", fromEpoch: 0)
        case .active(let coldkeySs58):
            flow.setConsent(active: true, coldkeySs58: coldkeySs58, fromEpoch: fromEpoch)
        }
        refresh()
    }

    /// A visit reads the store again: this is where a key returns after a
    /// logout, a crash or a reinstall.
    func visit(isGuest: Bool) {
        flow.setGuest(isGuest)
        flow.reload()
        refresh()
    }

    func setGuest(_ guest: Bool) {
        flow.setGuest(guest)
        refresh()
    }

    func setTop200Registered(_ registered: Bool) {
        flow.setTop200Registered(registered)
        refresh()
    }

    /// The earnings read, for "Payouts start next epoch" and the one reminder.
    func earningsRead(schedule: SnEpochScheduleInfo?, claimable: Bool) {
        flow.setCurrentEpoch(schedule?.epoch ?? 0)
        refresh()
        let reminder = flow.reminder(
            currentEpoch: schedule?.epoch ?? 0,
            claimOpenMillis: schedule?.claimOpenMillis ?? 0,
            epochBlocks: schedule?.epochBlocks ?? 0,
            claimable: claimable
        )
        reminderNotice.apply(reminder, flow: flow)
    }

    // MARK: the card

    /// The one tap. With a consent in force the warning comes first.
    func setUpPayouts() {
        if card.replacesPayoutWallet {
            pendingReplacement = .makeKey
        } else {
            flow.setUpPayouts(replaceConfirmed: false)
        }
    }

    func saveFirst() {
        if card.replacesPayoutWallet {
            pendingReplacement = .makeKey
        } else {
            flow.saveFirst(replaceConfirmed: false)
        }
    }

    func finishSetup() {
        if card.replacesPayoutWallet {
            pendingReplacement = .finishSetup
        } else {
            flow.finishSetup(replaceConfirmed: false)
        }
    }

    /// The user read the warning.
    func replacementConfirmedSetUp() {
        pendingReplacement = nil
        flow.setUpPayouts(replaceConfirmed: true)
    }

    func replacementConfirmedSaveFirst() {
        pendingReplacement = nil
        flow.saveFirst(replaceConfirmed: true)
    }

    func replacementConfirmedFinishSetup() {
        pendingReplacement = nil
        flow.finishSetup(replaceConfirmed: true)
    }

    func openKeyScreen() {
        flow.openScreen()
        refresh()
    }

    // MARK: the Key screen

    /// Tap to reveal. A stored key asks for device authentication first.
    func tapToReveal() async {
        let authenticated = await authenticatedIfNeeded()
        flow.reveal(authenticated: authenticated)
        refresh()
    }

    func hide() {
        flow.hide()
        refresh()
    }

    /// Left the foreground, or the window lost focus: the words hide.
    func leftForeground() {
        flow.hide()
        refresh()
    }

    /// The screen started or stopped being recorded or mirrored.
    func captureChanged(active: Bool) {
        flow.setCaptureActive(active)
        refresh()
    }

    func screenshotTaken() {
        if screen.open {
            screenshotWarning = true
        }
    }

    /// Copy. The flow answers only while the words show, so this can't copy
    /// while hidden.
    func copy() {
        let phrase = flow.phraseToCopy
        guard !phrase.isEmpty else {
            return
        }
        pasteboard.copy(phrase)
        copied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                self?.copied = false
            }
        }
    }

    /// I have saved the key, it's OK to delete it now.
    func confirmDelete() async {
        let authenticated = await authenticatedIfNeeded()
        flow.confirmDelete(authenticated: authenticated)
        refresh()
    }

    /// I've saved it, keep it on this device.
    func confirmKeep() async {
        let authenticated = await authenticatedIfNeeded()
        flow.confirmKeep(authenticated: authenticated)
        refresh()
    }

    func cancelConfirmation() {
        flow.cancelConfirmation()
        refresh()
    }

    func submitWords(first: String, second: String) {
        flow.submitWords(first: first, second: second)
    }

    func retry() {
        flow.retrySaveNow()
    }

    /// Leaving discards a phrase in memory: no earnings went to it.
    func closeScreen() {
        flow.closeScreen()
        refresh()
    }

    private func authenticatedIfNeeded() async -> Bool {
        guard screen.needsAuthentication else {
            return false
        }
        return await authenticator.authenticate(reason: String(localized: "use your Bittensor recovery phrase"))
    }
}
