//
//  BittensorKeyModelTests.swift
//  networkTests
//
//  What the app does around the SDK's payout key flow: device authentication
//  before a stored key shows, Copy only with what the flow hands out, the words
//  hiding when the app leaves the foreground, the warning before a replacement,
//  and the warnings at sign out and account deletion. The flow's decisions are
//  tested in the sdk; here a stand-in answers for it.
//

import Foundation
import Testing
import URnetworkSdk
#if os(macOS)
import AppKit
#endif
@testable import URnetwork

@MainActor
struct BittensorKeyModelTests {

    private struct Fixture {
        let flow = FakeBittensorKeyFlow()
        let authenticator = FakeBittensorAuthenticator()
        let pasteboard = FakeBittensorPasteboard()
        let poster = FakeBittensorReminderPoster()
    }

    private func make(_ fixture: Fixture) -> BittensorKeyModel {
        BittensorKeyModel(
            flow: fixture.flow,
            authenticator: fixture.authenticator,
            pasteboard: fixture.pasteboard,
            reminderNotice: fixture.poster
        )
    }

    // MARK: Key screen

    // a stored key asks for device authentication, and passes on the answer
    @Test func aStoredKeyAsksForDeviceAuthenticationBeforeItShows() async {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true, needsAuthentication: true)
        let model = make(fixture)

        await model.tapToReveal()
        #expect(fixture.authenticator.asked == 1)
        #expect(fixture.flow.calls.contains("reveal(true)"))

        fixture.authenticator.answer = false
        await model.tapToReveal()
        #expect(fixture.authenticator.asked == 2)
        #expect(fixture.flow.calls.last == "reveal(false)")

        await model.confirmDelete()
        #expect(fixture.authenticator.asked == 3)
        #expect(fixture.flow.calls.last == "confirmDelete(false)")

        await model.confirmKeep()
        #expect(fixture.authenticator.asked == 4)
        #expect(fixture.flow.calls.last == "confirmKeep(false)")
    }

    // Save now asks for nothing: the phrase signed nothing yet
    @Test func saveNowAsksForNoAuthentication() async {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true, saveNow: true, needsAuthentication: false)
        let model = make(fixture)
        await model.tapToReveal()
        await model.confirmDelete()
        #expect(fixture.authenticator.asked == 0)
        #expect(fixture.flow.calls.contains("reveal(false)"))
        #expect(fixture.flow.calls.contains("confirmDelete(false)"))
    }

    // Copy is impossible while hidden: the flow hands out nothing, and the
    // pasteboard is not touched
    @Test func copyIsImpossibleWhileHidden() {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true)
        let model = make(fixture)
        model.copy()
        #expect(fixture.pasteboard.copies.isEmpty)
        #expect(!model.copied)

        fixture.flow.screen.revealed = true
        fixture.flow.phraseToCopy = "the phrase"
        model.refresh()
        model.copy()
        #expect(fixture.pasteboard.copies == ["the phrase"])
        #expect(model.copied)

        fixture.flow.screen.revealed = false
        fixture.flow.phraseToCopy = ""
        model.refresh()
        model.copy()
        #expect(fixture.pasteboard.copies == ["the phrase"])
    }

    // the words are in the model only while they show
    @Test func theWordsLeaveWithTheReveal() {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true, revealed: true)
        fixture.flow.revealedWords = ["one", "two"]
        let model = make(fixture)
        model.refresh()
        #expect(model.words == ["one", "two"])

        fixture.flow.screen.revealed = false
        // an answer the flow should not give is not shown either
        model.refresh()
        #expect(model.words.isEmpty)
    }

    // leaving the foreground or losing focus hides the words
    @Test func leavingTheForegroundHidesTheWords() {
        let fixture = Fixture()
        let model = make(fixture)
        model.leftForeground()
        #expect(fixture.flow.calls == ["hide"])
    }

    @Test func recordingHidesTheWordsAndAScreenshotWarns() {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true)
        let model = make(fixture)
        model.refresh()
        model.captureChanged(active: true)
        #expect(fixture.flow.calls == ["setCaptureActive(true)"])

        model.screenshotTaken()
        #expect(model.screenshotWarning)
        // the warning does not outlive the screen
        fixture.flow.screen.open = false
        model.refresh()
        #expect(!model.screenshotWarning)
        model.screenshotTaken()
        #expect(!model.screenshotWarning)
    }

    // a finished screen closes itself
    @Test func aFinishedScreenCloses() {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true, done: true)
        let model = make(fixture)
        model.refresh()
        #expect(fixture.flow.calls.contains("closeScreen"))
        #expect(!model.screen.open)
    }

    @Test func leavingTellsTheFlow() {
        let fixture = Fixture()
        fixture.flow.screen = BittensorKeyScreenInfo(open: true, saveNow: true)
        let model = make(fixture)
        model.closeScreen()
        #expect(fixture.flow.calls.contains("closeScreen"))
    }

    // MARK: the card

    // with no consent the one tap goes straight through: no screen, no question
    @Test func theOneTapAsksNothing() {
        let fixture = Fixture()
        fixture.flow.card = BittensorKeyCardInfo(state: SdkBittensorLocalKeyStateNone, offersSetUp: true, offersSaveFirst: true)
        let model = make(fixture)
        model.setUpPayouts()
        model.saveFirst()
        #expect(fixture.flow.calls == ["setUpPayouts(false)", "saveFirst(false)"])
        #expect(model.pendingReplacement == nil)
        #expect(fixture.authenticator.asked == 0)
    }

    // with a consent in force nothing happens until the warning is answered
    @Test func replacingAPayoutWalletWarnsFirst() {
        let fixture = Fixture()
        fixture.flow.card = BittensorKeyCardInfo(state: SdkBittensorLocalKeyStateElsewhere, offersSetUp: true, offersSaveFirst: true, replacesPayoutWallet: true)
        let model = make(fixture)
        model.setUpPayouts()
        #expect(model.pendingReplacement == .makeKey)
        #expect(fixture.flow.calls.isEmpty)
        model.replacementConfirmedSetUp()
        #expect(fixture.flow.calls == ["setUpPayouts(true)"])
        #expect(model.pendingReplacement == nil)

        model.saveFirst()
        #expect(model.pendingReplacement == .makeKey)
        model.replacementConfirmedSaveFirst()
        #expect(fixture.flow.calls.last == "saveFirst(true)")

        fixture.flow.card = BittensorKeyCardInfo(state: SdkBittensorLocalKeyStateSaveLaterNotLinked, offersFinishSetup: true, replacesPayoutWallet: true)
        model.refresh()
        model.finishSetup()
        #expect(model.pendingReplacement == .finishSetup)
        model.replacementConfirmedFinishSetup()
        #expect(fixture.flow.calls.last == "finishSetup(true)")
    }

    @Test func finishSetupGoesStraightThroughWithNoConsent() {
        let fixture = Fixture()
        fixture.flow.card = BittensorKeyCardInfo(state: SdkBittensorLocalKeyStateSaveLaterNotLinked, offersFinishSetup: true)
        let model = make(fixture)
        model.finishSetup()
        #expect(fixture.flow.calls == ["finishSetup(false)"])
    }

    // a consent the flow got accepted reads everything again, once
    @Test func aNewLinkReadsEarningsAgain() {
        let fixture = Fixture()
        let model = make(fixture)
        var linked = 0
        model.onLinked = { linked += 1 }
        model.refresh()
        #expect(linked == 0)
        fixture.flow.card.linkGeneration = 1
        model.refresh()
        model.refresh()
        #expect(linked == 1)
    }

    // the flow works from the app's own consent read: the latest read decides
    @Test func theConsentReadReachesTheFlow() {
        let fixture = Fixture()
        let model = make(fixture)
        model.consentRead(.loading, fromEpoch: 0)
        #expect(fixture.flow.calls.isEmpty)
        model.consentRead(.noConsent, fromEpoch: 0)
        #expect(fixture.flow.calls.last == "setConsent(false, , 0)")
        model.consentRead(.active(coldkeySs58: "5Abc"), fromEpoch: 43)
        #expect(fixture.flow.calls.last == "setConsent(true, 5Abc, 43)")
        model.consentRead(.unavailable, fromEpoch: 0)
        #expect(fixture.flow.calls.last == "setConsentUnavailable")
    }

    // a visit reads the store again: where a key comes back
    @Test func aVisitReadsTheStoreAgain() {
        let fixture = Fixture()
        let model = make(fixture)
        model.visit(isGuest: true)
        #expect(fixture.flow.calls == ["setGuest(true)", "reload"])
    }

    // the earnings read reaches the flow, and the app does what it says
    @Test func theReminderFollowsTheFlow() {
        let fixture = Fixture()
        fixture.flow.reminderAnswer = BittensorKeyReminderInfo(action: SdkBittensorLocalKeyReminderSchedule, atMillis: 5)
        let model = make(fixture)
        let schedule = SnEpochScheduleInfo(epoch: 42, endMillis: 1, claimOpenMillis: 2, expiryMillis: 3, epochBlocks: 50400)
        model.earningsRead(schedule: schedule, claimable: true)
        #expect(fixture.flow.calls == ["setCurrentEpoch(42)", "reminder(42, 2, 50400, true)"])
        #expect(fixture.poster.applied == [BittensorKeyReminderInfo(action: SdkBittensorLocalKeyReminderSchedule, atMillis: 5)])

        model.earningsRead(schedule: nil, claimable: false)
        #expect(fixture.flow.calls.suffix(2) == ["setCurrentEpoch(0)", "reminder(0, 0, 0, false)"])
    }

    // a key saved or deleted takes back the notification still on its way
    @Test func theReminderEndsWithTheBackup() {
        let fixture = Fixture()
        fixture.flow.card = BittensorKeyCardInfo(state: SdkBittensorLocalKeyStateSaveLaterLinked, backupReminder: true)
        let model = make(fixture)
        fixture.flow.reminderAnswer = BittensorKeyReminderInfo(action: SdkBittensorLocalKeyReminderCancel)
        model.refresh()
        #expect(fixture.poster.applied.isEmpty)

        fixture.flow.card.backupReminder = false
        model.refresh()
        #expect(fixture.poster.applied == [BittensorKeyReminderInfo(action: SdkBittensorLocalKeyReminderCancel)])
        model.refresh()
        #expect(fixture.poster.applied.count == 1)
    }

    @Test func theFlowEndsWithTheModel() {
        let fixture = Fixture()
        do {
            _ = make(fixture)
        }
        #expect(fixture.flow.calls == ["close"])
    }

    // MARK: words

    // what each sdk failure reads as
    @Test func eachFailureHasItsWords() {
        #expect(BittensorKeyText.failure(code: "", message: "x") == nil)
        #expect(BittensorKeyText.failure(code: SdkSnErrorCodeChallengeExpired, message: "x") == NetworkConsentFailure.expired.text)
        #expect(BittensorKeyText.failure(code: SdkSnErrorCodeSignatureMismatch, message: "x") == NetworkConsentFailure.signatureMismatch.text)
        #expect(BittensorKeyText.failure(code: SdkSnErrorCodeNetworkOwnerOnly, message: "x") == NetworkConsentFailure.ownerOnly.text)
        #expect(BittensorKeyText.failure(code: SdkBittensorLocalKeyFailureNotAllowed, message: "x") == NetworkConsentFailure.ownerOnly.text)
        for code in [
            SdkBittensorLocalKeyFailureGenerate,
            SdkBittensorLocalKeyFailureStore,
            SdkBittensorLocalKeyFailureStoreUnavailable,
            SdkBittensorLocalKeyFailureDelete,
            SdkBittensorLocalKeyFailureReplacementNotConfirmed,
        ] {
            let text = BittensorKeyText.failure(code: code, message: "the raw text")
            #expect(text?.isEmpty == false)
            #expect(text != "the raw text")
        }
        #expect(BittensorKeyText.failure(code: SdkBittensorLocalKeyFailureConsent, message: "server_error: 500") == "server_error: 500")
        #expect(BittensorKeyText.failure(code: SdkBittensorLocalKeyFailureConsent, message: "")?.isEmpty == false)
    }

    // MARK: sign out

    // with an unsaved key a sign out waits for the answer; otherwise it runs
    @Test func aSignOutWarnsOnlyWhileAKeyIsUnsaved() {
        var networkAsked: String?
        var needsBackup = false
        let signOut = BittensorKeySignOut(needsBackup: {
            networkAsked = $0
            return needsBackup
        })

        var ran = 0
        signOut.request(networkId: "network") { ran += 1 }
        #expect(networkAsked == "network")
        #expect(ran == 1)
        #expect(signOut.pending == nil)

        needsBackup = true
        signOut.request(networkId: "network") { ran += 1 }
        #expect(ran == 1)
        #expect(signOut.pending != nil)
        signOut.cancel()
        #expect(ran == 1)
        #expect(signOut.pending == nil)

        signOut.request(networkId: "network") { ran += 1 }
        signOut.confirm()
        #expect(ran == 2)
        #expect(signOut.pending == nil)
    }

    // the sessions screen's own confirmation warns for this session only
    @Test func theSessionsConfirmationWarnsForThisSession() {
        let sessionId = "a-session"
        let current = SessionsConfirmation.signOut(sessionId: sessionId, device: "Mac", place: "", current: true)
        #expect(current.message(keyNeedsBackup: false) == current.message)
        #expect(current.message(keyNeedsBackup: true).hasPrefix(current.message))
        #expect(current.message(keyNeedsBackup: true).hasSuffix(BittensorKeySignOut.warning))

        let other = SessionsConfirmation.signOut(sessionId: sessionId, device: "Mac", place: "", current: false)
        #expect(other.message(keyNeedsBackup: true) == other.message)
        #expect(SessionsConfirmation.signOutOthers.message(keyNeedsBackup: true) == SessionsConfirmation.signOutOthers.message)
    }

    // MARK: the platform

    #if os(iOS)
    // this iOS still has the secure layer the words are drawn in; if a new iOS
    // removes it, this fails, and the capture check on the report's list matters
    @Test func thisIosHasTheSecureLayer() {
        let view = BittensorKeyCaptureProtectedView(content: BittensorKeyWordGrid(
            words: ["one", "two"],
            columns: 2,
            textColor: .white,
            mutedColor: .gray,
            background: .black
        ))
        #expect(view.isProtected)
        #expect(view.fittingSize(width: 320).height > 0)
    }
    #endif

    #if os(macOS)
    private final class FakeMacPasteboard: BittensorKeyMacPasteboard {
        var changeCount = 10
        var contents: String?

        func writeConcealed(_ text: String) -> Int {
            changeCount += 1
            contents = text
            return changeCount
        }

        func clearContents() -> Int {
            changeCount += 1
            contents = nil
            return changeCount
        }
    }

    // cleared after 60 s if it still holds the phrase, and left alone if the
    // user copied something else since
    @Test func theMacClearsThePasteboardIfItStillHoldsThePhrase() {
        let pasteboard = FakeMacPasteboard()
        var scheduled: [(TimeInterval, () -> Void)] = []
        let copier = BittensorKeyPasteboard(pasteboard: pasteboard, schedule: { delay, work in
            scheduled.append((delay, work))
        })
        copier.copy("the phrase")
        #expect(pasteboard.contents == "the phrase")
        #expect(scheduled.count == 1)
        #expect(scheduled[0].0 == 60)
        scheduled[0].1()
        #expect(pasteboard.contents == nil)

        copier.copy("the phrase")
        // the user copied something else
        pasteboard.changeCount += 1
        pasteboard.contents = "something else"
        scheduled[1].1()
        #expect(pasteboard.contents == "something else")
    }

    // the Key screen's window stays out of sharing and capture while it holds
    // the screen, and goes back to how it was
    @Test func theSharingSettingFollowsTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(window.sharingType != .none)
        let view = BittensorKeyWindowPrivacyView()
        window.contentView?.addSubview(view)
        #expect(window.sharingType == .none)
        view.removeFromSuperview()
        #expect(window.sharingType != .none)
        window.close()
    }
    #endif
}
