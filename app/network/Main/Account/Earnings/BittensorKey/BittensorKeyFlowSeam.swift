//
//  BittensorKeyFlowSeam.swift
//  URnetwork
//
//  The door to the SDK's payout key flow (sdk BittensorLocalKeyFlow): the state
//  model, what the card shows, and the rule that nothing signs until the phrase
//  is safe all live there, with their tests, so every app has the same ones. The
//  screens read value types from here, never gomobile objects, and a test or a
//  preview hands them a stand-in for the flow.
//

import Foundation
import URnetworkSdk

/// What the payout card shows (sdk BittensorLocalKeyCard). Holds no secret.
struct BittensorKeyCardInfo: Equatable {
    var state: String = SdkBittensorLocalKeyStateLoading
    var address: String = ""
    var storedAddress: String = ""
    var showsKeyPath = false
    var offersSetUp = false
    var offersSaveFirst = false
    var offersWallet = false
    var offersFinishSetup = false
    var offersKeyScreen = false
    var replacesPayoutWallet = false
    var ownerOnly = false
    var payoutsStartNextEpoch = false
    var backupReminder = false
    var keySaved = false
    var busy = false
    var linkGeneration: Int64 = 0
    var failureCode: String = ""
    var failureMessage: String = ""
}

/// What the Key screen shows (sdk BittensorLocalKeyScreen). Holds no secret:
/// the words come only from revealedWords, while they show.
struct BittensorKeyScreenInfo: Equatable {
    var open = false
    var saveNow = false
    var address: String = ""
    var revealed = false
    var needsAuthentication = false
    var hiddenByCapture = false
    var confirming: String = SdkBittensorLocalKeyConfirmNone
    var firstWordPosition = 0
    var secondWordPosition = 0
    var wordsRejected = false
    var warnsTop200 = false
    var offersKeep = false
    var offersRetry = false
    var busy = false
    var done = false
    var failureCode: String = ""
    var failureMessage: String = ""
}

/// What to do about the one reminder of an unsaved key (sdk
/// BittensorLocalKeyReminder).
struct BittensorKeyReminderInfo: Equatable {
    var action: String = SdkBittensorLocalKeyReminderNone
    var atMillis: Int64 = 0
}

protocol BittensorKeyFlowing: AnyObject {
    var card: BittensorKeyCardInfo { get }
    var screen: BittensorKeyScreenInfo { get }
    /// empty while hidden
    var revealedWords: [String] { get }
    /// "" while hidden, so there is no Copy then
    var phraseToCopy: String { get }

    /// on an arbitrary thread
    func onChange(_ handler: @escaping () -> Void)
    func reload()
    func setConsent(active: Bool, coldkeySs58: String, fromEpoch: Int64)
    func setConsentUnavailable()
    func setCurrentEpoch(_ currentEpoch: Int64)
    func setGuest(_ guest: Bool)
    func setTop200Registered(_ registered: Bool)

    func setUpPayouts(replaceConfirmed: Bool)
    func finishSetup(replaceConfirmed: Bool)
    func saveFirst(replaceConfirmed: Bool)
    func retrySaveNow()

    func openScreen()
    func closeScreen()
    func reveal(authenticated: Bool)
    func hide()
    func setCaptureActive(_ active: Bool)
    func confirmDelete(authenticated: Bool)
    func confirmKeep(authenticated: Bool)
    func cancelConfirmation()
    func submitWords(first: String, second: String)

    func reminder(currentEpoch: Int64, claimOpenMillis: Int64, epochBlocks: Int64, claimable: Bool) -> BittensorKeyReminderInfo
    func reminderScheduled(atMillis: Int64)
    func reminderDelivered()

    func close()
}

/// The SDK's flow.
final class SdkBittensorKeyFlow: NSObject, BittensorKeyFlowing, SdkBittensorLocalKeyFlowListenerProtocol {

    private let flow: SdkBittensorLocalKeyFlow?
    private var subscription: SdkSubProtocol?
    private let handlerLock = NSLock()
    private var handler: (() -> Void)?

    init(api: SdkApi?, networkId: String?, store: BittensorLocalKeyStore) {
        flow = SdkNewBittensorLocalKeyFlow(api, networkId ?? "", store)
        super.init()
    }

    func onChange(_ handler: @escaping () -> Void) {
        handlerLock.withLock {
            self.handler = handler
        }
        if subscription == nil {
            subscription = flow?.add(self)
        }
    }

    func bittensorLocalKeyFlowChanged() {
        let handler = handlerLock.withLock { self.handler }
        handler?()
    }

    var card: BittensorKeyCardInfo {
        guard let card = flow?.getCard() else {
            return BittensorKeyCardInfo()
        }
        return BittensorKeyCardInfo(
            state: card.state,
            address: card.address,
            storedAddress: card.storedAddress,
            showsKeyPath: card.showsKeyPath,
            offersSetUp: card.offersSetUp,
            offersSaveFirst: card.offersSaveFirst,
            offersWallet: card.offersWallet,
            offersFinishSetup: card.offersFinishSetup,
            offersKeyScreen: card.offersKeyScreen,
            replacesPayoutWallet: card.replacesPayoutWallet,
            ownerOnly: card.ownerOnly,
            payoutsStartNextEpoch: card.payoutsStartNextEpoch,
            backupReminder: card.backupReminder,
            keySaved: card.keySaved,
            busy: card.busy,
            linkGeneration: card.linkGeneration,
            failureCode: card.failureCode,
            failureMessage: card.failureMessage
        )
    }

    var screen: BittensorKeyScreenInfo {
        guard let screen = flow?.getScreen() else {
            return BittensorKeyScreenInfo()
        }
        return BittensorKeyScreenInfo(
            open: screen.open,
            saveNow: screen.saveNow,
            address: screen.address,
            revealed: screen.revealed,
            needsAuthentication: screen.needsAuthentication,
            hiddenByCapture: screen.hiddenByCapture,
            confirming: screen.confirming,
            firstWordPosition: screen.firstWordPosition,
            secondWordPosition: screen.secondWordPosition,
            wordsRejected: screen.wordsRejected,
            warnsTop200: screen.warnsTop200,
            offersKeep: screen.offersKeep,
            offersRetry: screen.offersRetry,
            busy: screen.busy,
            done: screen.done,
            failureCode: screen.failureCode,
            failureMessage: screen.failureMessage
        )
    }

    var revealedWords: [String] {
        guard let list = flow?.revealedWords() else {
            return []
        }
        return (0..<list.len()).map { list.get($0) }
    }

    var phraseToCopy: String {
        flow?.phraseToCopy() ?? ""
    }

    func reload() {
        flow?.reload()
    }

    func setConsent(active: Bool, coldkeySs58: String, fromEpoch: Int64) {
        flow?.setConsent(active, coldkeySs58: coldkeySs58, fromEpoch: fromEpoch)
    }

    func setConsentUnavailable() {
        flow?.setConsentUnavailable()
    }

    func setCurrentEpoch(_ currentEpoch: Int64) {
        flow?.setCurrentEpoch(currentEpoch)
    }

    func setGuest(_ guest: Bool) {
        flow?.setGuest(guest)
    }

    func setTop200Registered(_ registered: Bool) {
        flow?.setTop200Registered(registered)
    }

    func setUpPayouts(replaceConfirmed: Bool) {
        flow?.setUpPayouts(replaceConfirmed)
    }

    func finishSetup(replaceConfirmed: Bool) {
        flow?.finishSetup(replaceConfirmed)
    }

    func saveFirst(replaceConfirmed: Bool) {
        flow?.saveFirst(replaceConfirmed)
    }

    func retrySaveNow() {
        flow?.retrySaveNow()
    }

    func openScreen() {
        flow?.openScreen()
    }

    func closeScreen() {
        flow?.closeScreen()
    }

    func reveal(authenticated: Bool) {
        flow?.reveal(authenticated)
    }

    func hide() {
        flow?.hide()
    }

    func setCaptureActive(_ active: Bool) {
        flow?.setCaptureActive(active)
    }

    func confirmDelete(authenticated: Bool) {
        flow?.confirmDelete(authenticated)
    }

    func confirmKeep(authenticated: Bool) {
        flow?.confirmKeep(authenticated)
    }

    func cancelConfirmation() {
        flow?.cancelConfirmation()
    }

    func submitWords(first: String, second: String) {
        flow?.submitWords(first, secondWord: second)
    }

    func reminder(currentEpoch: Int64, claimOpenMillis: Int64, epochBlocks: Int64, claimable: Bool) -> BittensorKeyReminderInfo {
        guard let reminder = flow?.reminder(currentEpoch, claimOpenMillis: claimOpenMillis, epochBlocks: epochBlocks, claimable: claimable) else {
            return BittensorKeyReminderInfo()
        }
        return BittensorKeyReminderInfo(action: reminder.action, atMillis: reminder.atMillis)
    }

    func reminderScheduled(atMillis: Int64) {
        flow?.reminderScheduled(atMillis)
    }

    func reminderDelivered() {
        flow?.reminderDelivered()
    }

    func close() {
        subscription?.close()
        subscription = nil
        flow?.close()
    }
}

/// Canned states for previews. A real phrase never reaches a preview.
final class BittensorKeyPreviewFlow: BittensorKeyFlowing {

    var card = BittensorKeyCardInfo(state: SdkBittensorLocalKeyStateNone, showsKeyPath: true, offersSetUp: true, offersSaveFirst: true, offersWallet: true)
    var screen = BittensorKeyScreenInfo()
    var revealedWords: [String] = []
    var phraseToCopy = ""

    func onChange(_ handler: @escaping () -> Void) {}
    func reload() {}
    func setConsent(active: Bool, coldkeySs58: String, fromEpoch: Int64) {}
    func setConsentUnavailable() {}
    func setCurrentEpoch(_ currentEpoch: Int64) {}
    func setGuest(_ guest: Bool) {}
    func setTop200Registered(_ registered: Bool) {}
    func setUpPayouts(replaceConfirmed: Bool) {}
    func finishSetup(replaceConfirmed: Bool) {}
    func saveFirst(replaceConfirmed: Bool) {}
    func retrySaveNow() {}
    func openScreen() {}
    func closeScreen() {}
    func reveal(authenticated: Bool) {}
    func hide() {}
    func setCaptureActive(_ active: Bool) {}
    func confirmDelete(authenticated: Bool) {}
    func confirmKeep(authenticated: Bool) {}
    func cancelConfirmation() {}
    func submitWords(first: String, second: String) {}
    func reminder(currentEpoch: Int64, claimOpenMillis: Int64, epochBlocks: Int64, claimable: Bool) -> BittensorKeyReminderInfo {
        BittensorKeyReminderInfo()
    }
    func reminderScheduled(atMillis: Int64) {}
    func reminderDelivered() {}
    func close() {}
}
