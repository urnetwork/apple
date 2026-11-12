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
        /// a new key, in one tap
        case setUp
        /// a new key, its phrase saved first
        case saveFirst
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
    /// what deleting means, before the two words are asked: the step the
    /// delete's Continue leaves
    @Published private(set) var deleteExplained = false

    let flow: BittensorKeyFlowing
    private let authenticator: BittensorDeviceAuthenticating
    private let pasteboard: BittensorKeyPasteboarding
    private let reminderNotice: BittensorKeyReminderPosting
    private var observedLinkGeneration: Int64 = 0
    private var copiedResetTask: Task<Void, Never>?

    /// A consent went through this flow: read the consent and earnings again.
    /// nil while no screen listens (EarningsView sets it while it is on
    /// screen); a link that lands meanwhile, while Earnings is covered or away,
    /// is handed on when one sets it again, never lost.
    var onLinked: (() -> Void)? {
        didSet {
            handOnLink()
        }
    }

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
        // a consent on its way finishes first (BittensorKeyFlowEnd)
        BittensorKeyFlowEnd.end(flow)
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
            deleteExplained = false
        }
        if screen.confirming != SdkBittensorLocalKeyConfirmNone {
            deleteExplained = false
        }
        handOnLink()
    }

    /// A link the flow made since the last one handed on goes to the screen
    /// that listens, once; it waits while none does.
    private func handOnLink() {
        guard let onLinked, card.linkGeneration != observedLinkGeneration else {
            return
        }
        observedLinkGeneration = card.linkGeneration
        onLinked()
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
            pendingReplacement = .setUp
        } else {
            flow.setUpPayouts(replaceConfirmed: false)
        }
    }

    func saveFirst() {
        if card.replacesPayoutWallet {
            pendingReplacement = .saveFirst
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

    /// The user read the warning and replaces the payout wallet.
    func replacementConfirmed() {
        let pending = pendingReplacement
        pendingReplacement = nil
        switch pending {
        case .setUp:
            flow.setUpPayouts(replaceConfirmed: true)
        case .saveFirst:
            flow.saveFirst(replaceConfirmed: true)
        case .finishSetup:
            flow.finishSetup(replaceConfirmed: true)
        case nil:
            break
        }
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

    /// I have saved the key, it's OK to delete it now: what deleting means
    /// comes first. The words hide before it shows, so none can be read
    /// behind it.
    func explainDelete() {
        hide()
        deleteExplained = true
    }

    func cancelDelete() {
        deleteExplained = false
    }

    /// Continue: two of the words are asked for.
    func confirmDelete() {
        deleteExplained = false
        flow.confirmDelete()
        refresh()
    }

    /// I've saved it. Keep it on this device: two of the words, and no device
    /// authentication, since keeping shows and deletes nothing. The words
    /// hide first.
    func confirmKeep() {
        flow.confirmKeep()
        refresh()
    }

    func cancelConfirmation() {
        flow.cancelConfirmation()
        refresh()
    }

    /// The two words as the user types them.
    func checkWords(first: String, second: String) -> BittensorKeyWordCheckInfo {
        flow.checkWords(first: first, second: second)
    }

    /// The confirmation's button. Deleting a stored key asks for device
    /// authentication first, at the button, after the words.
    func submitWords(first: String, second: String) async {
        var authenticated = false
        if screen.confirmNeedsAuthentication {
            authenticated = await authenticator.authenticate(reason: String(localized: "use your Bittensor recovery phrase"))
            guard authenticated else {
                return
            }
        }
        flow.submitWords(first: first, second: second, authenticated: authenticated)
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

/// Ends the flow of a key model that went with its screen. The SDK's Close
/// cancels a consent on its way (sdk BittensorLocalKeyFlow.Close), which would
/// leave a key the one tap made stored but not linked when the user leaves
/// Earnings before the consent lands. So a flow still busy is kept until the
/// consent lands or fails, then closed; one that is not is closed at once.
/// (Android's flow lives with its activity's view model, past the Earnings
/// screen, so leaving it never cancels a consent there either.)
enum BittensorKeyFlowEnd {

    private static let lock = NSLock()
    private static var finishing: [Int: BittensorKeyFlowing] = [:]
    private static var lastToken = 0

    static func end(_ flow: BittensorKeyFlowing) {
        guard flow.card.busy else {
            flow.close()
            return
        }
        let token = lock.withLock { () -> Int in
            lastToken += 1
            finishing[lastToken] = flow
            return lastToken
        }
        // the flow calls back on its own goroutine; the card is read on the
        // main queue, as the model reads it
        flow.onChange {
            DispatchQueue.main.async {
                closeIfIdle(token)
            }
        }
        // the consent may have landed before the handler was in place
        DispatchQueue.main.async {
            closeIfIdle(token)
        }
    }

    /// `flow` is kept until its consent lands
    static func isFinishing(_ flow: BittensorKeyFlowing) -> Bool {
        lock.withLock { finishing.values.contains { $0 === flow } }
    }

    private static func closeIfIdle(_ token: Int) {
        guard let flow = lock.withLock({ finishing[token] }), !flow.card.busy else {
            return
        }
        let ending = lock.withLock { finishing.removeValue(forKey: token) != nil }
        if ending {
            flow.close()
        }
    }
}
