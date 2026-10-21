//
//  CryptoInvoiceStoreTests.swift
//  networkTests
//
//  The direct-download build's crypto invoice flow (mmm/ZCASH-CONTRACT.md
//  §4.4, §6.1–§6.2) over a fake CryptoInvoiceViewController: what the store
//  asks the SDK for, and what a billing surface does with each transition (the
//  invoice over the plans, "Temporarily unavailable" under the row, the
//  existing refusal handling, the add-sign-in sheet, the success state and
//  the balance refresh, the events with the method's store), and that the
//  controller runs only while something shows the invoice and the app is
//  active. Nothing here polls, waits or reads a clock.
//

import Foundation
import Testing
@testable import URnetwork

@MainActor
final class FakeCryptoInvoiceController: CryptoInvoiceControlling {

    var onChange: (() -> Void)?
    var state = CryptoInvoiceSnapshot()
    var paymentMethod: String = ""
    /// What Resume finds saved for the signed-in network.
    var saved: CryptoInvoiceSnapshot? = nil
    var calls: [String] = []

    func start() {
        calls.append("start")
    }

    func stop() {
        calls.append("stop")
    }

    func startInvoice(asset: String, plan: String, itemId: String, storefrontCountry: String) {
        calls.append("startInvoice:\(asset):\(plan):\(itemId):\(storefrontCountry)")
        var starting = CryptoInvoiceSnapshot()
        starting.phaseName = "starting"
        starting.asset = asset
        starting.plan = plan
        state = starting
    }

    func resume() -> Bool {
        calls.append("resume")
        switch state.phase {
        case .starting, .open, .paid:
            return true
        case .none, .failed:
            guard let saved else {
                return false
            }
            state = saved
            return true
        }
    }

    func requote() {
        calls.append("requote")
    }

    func dismiss() {
        calls.append("dismiss")
        state = CryptoInvoiceSnapshot()
    }

    func setPaymentMethod(_ method: String) {
        calls.append("setPaymentMethod:\(method)")
        paymentMethod = method
    }

    /// The SDK reports a new state (its listener, on the main actor).
    func emit(_ snapshot: CryptoInvoiceSnapshot) {
        state = snapshot
        onChange?()
    }
}

@MainActor
private final class EventLog {
    var events: [CryptoPurchaseEvent] = []
}

@MainActor
struct CryptoInvoiceStoreTests {

    private let controller = FakeCryptoInvoiceController()
    private let log = EventLog()

    private func makeStore() -> CryptoInvoiceStore {
        let log = self.log
        return CryptoInvoiceStore(
            controller: controller,
            catalog: CryptoPaymentRulesTests.catalog,
            recordEvent: { event in log.events.append(event) }
        )
    }

    nonisolated private static func open(_ asset: String = "xmr", plan: String = "yearly", status: String = "pending") -> CryptoInvoiceSnapshot {
        var snapshot = CryptoPaymentRulesTests.openXmr()
        snapshot.asset = asset
        snapshot.plan = plan
        snapshot.status = status
        return snapshot
    }

    nonisolated private static func failed(_ code: String, _ message: String = "", asset: String = "xmr") -> CryptoInvoiceSnapshot {
        var snapshot = CryptoInvoiceSnapshot()
        snapshot.phaseName = "failed"
        snapshot.asset = asset
        snapshot.plan = "yearly"
        snapshot.errorCode = code
        snapshot.errorMessage = message
        return snapshot
    }

    nonisolated private static func paid(_ snapshot: CryptoInvoiceSnapshot = open()) -> CryptoInvoiceSnapshot {
        var paid = snapshot
        paid.phaseName = "paid"
        paid.status = "paid"
        return paid
    }

    // MARK: the method row

    @Test func theRememberedMethodIsTheSdksPerDeviceChoice() {
        controller.paymentMethod = "zec"
        let store = makeStore()
        #expect(store.rememberedMethod == "zec")
        let row = store.methodRow(listed: ["card", "usdc_solana", "zec"])
        #expect(row.methods == [.card, .usdcSolana, .zec])
        #expect(row.selected == .zec)
        #expect(row.isShown)
        // the server stopped listing it: Card, and no row with Card alone
        let cardOnly = store.methodRow(listed: ["card"])
        #expect(cardOnly.selected == .card)
        #expect(!cardOnly.isShown)
    }

    @Test func aPickIsRememberedOnTheDevice() {
        let store = makeStore()
        store.choose(.xmr)
        #expect(controller.calls == ["setPaymentMethod:xmr"])
        #expect(store.rememberedMethod == "xmr")
        #expect(store.methodRow(listed: ["card", "xmr"]).selected == .xmr)
    }

    @Test func monthlyIsCardOnly() {
        let store = makeStore()
        #expect(store.methodRow(listed: ["card", "xmr"]).allowsMonthly)
        store.choose(.xmr)
        #expect(!store.methodRow(listed: ["card", "xmr"]).allowsMonthly)
        store.choose(.card)
        #expect(store.methodRow(listed: ["card", "xmr"]).allowsMonthly)
    }

    // MARK: starting

    @Test func aCoinStartsAnInvoiceAndShowsIt() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        #expect(controller.calls == ["startInvoice:xmr:yearly::"])
        #expect(store.isPresented)
        #expect(store.display.isStarting)
        #expect(store.hasInvoiceInProgress)
        // nothing is recorded before the server quotes
        #expect(log.events.isEmpty)
    }

    @Test func theWelcomeOffersYearAndTheStorefrontGoToTheSdk() {
        let store = makeStore()
        store.startInvoice(.usdcSolana, plan: "yearly_onboarding", storefrontCountry: "US")
        #expect(controller.calls == ["startInvoice:usdc_solana:yearly_onboarding::US"])
    }

    @Test func cardStartsNoInvoice() {
        let store = makeStore()
        store.startInvoice(.card, plan: "yearly", storefrontCountry: nil)
        #expect(controller.calls.isEmpty)
        #expect(!store.isPresented)
    }

    @Test func theQuoteRecordsThePurchaseStartOnceWithTheMethodsStore() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly_onboarding", storefrontCountry: nil)
        controller.emit(Self.open(plan: "yearly_onboarding"))
        controller.emit(Self.open(plan: "yearly_onboarding"))
        #expect(log.events == [
            // the event schema names the offer's year yearly
            CryptoPurchaseEvent(kind: .started, method: .xmr, plan: "yearly", priceUsd: 40),
        ])
        #expect(store.snapshot.phase == .open)
        #expect(store.display.paymentUri == CryptoPaymentRulesTests.xmrUri)
    }

    @Test func assetUnavailableMarksTheCoinAndKeepsItSelectable() {
        let store = makeStore()
        store.choose(.xmr)
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.failed("asset_unavailable", "Monero is unavailable"))
        #expect(!store.isPresented)
        #expect(store.unavailableMethods == [.xmr])
        #expect(store.refusal == nil)
        #expect(log.events == [CryptoPurchaseEvent(kind: .failed(errorClass: "asset_unavailable"), method: .xmr, plan: "yearly", priceUsd: -1)])
        let row = store.methodRow(listed: ["card", "xmr"])
        #expect(row.selected == .xmr)
        #expect(row.selectedUnavailable)

        // a retry clears the line while it starts, and a quote keeps it clear
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        #expect(store.unavailableMethods.isEmpty)
        #expect(store.isPresented)
        controller.emit(Self.open())
        #expect(!store.methodRow(listed: ["card", "xmr"]).selectedUnavailable)
    }

    @Test func aGuestRefusalOpensTheAddSignInSheetInsteadOfAnError() {
        let store = makeStore()
        store.startInvoice(.usdcSolana, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.failed("guest_sign_in_required", asset: "usdc_solana"))
        #expect(store.guestSignInRequiredSequence == 1)
        #expect(store.refusal == nil)
        #expect(store.unavailableMethods.isEmpty)
        #expect(!store.isPresented)
    }

    @Test func otherRefusalsGoToTheSurfacesRefusalHandling() {
        let store = makeStore()
        store.startInvoice(.zec, plan: "yearly_onboarding", storefrontCountry: nil)
        controller.emit(Self.failed("offer_unavailable", "The welcome offer has ended.", asset: "zec"))
        #expect(store.refusal == CryptoPurchaseRefusal(code: "offer_unavailable", message: "The welcome offer has ended."))
        #expect(store.unavailableMethods.isEmpty)
        #expect(!store.isPresented)
        // the surface words it as the card checkout's refusals read
        #expect(CheckoutRefusal.message(code: "offer_unavailable", words: "The welcome offer has ended.", screenLine: "Something went wrong. Please try again later.")
            == "Something went wrong. Please try again later.\nThe welcome offer has ended.")

        // a new pick or a reset clears it
        store.choose(.card)
        #expect(store.refusal == nil)
    }

    @Test func aTransportFailureIsRecordedAsSuch() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.failed("", "timeout"))
        #expect(store.refusal == CryptoPurchaseRefusal(code: "", message: "timeout"))
        #expect(log.events == [CryptoPurchaseEvent(kind: .failed(errorClass: "transport"), method: .xmr, plan: "yearly", priceUsd: -1)])
    }

    @Test func aFailureNobodyStartedChangesNothingOnTheSurface() {
        // a resumed invoice the server no longer knows: the invoice says so
        controller.saved = Self.open()
        let store = makeStore()
        #expect(store.resume())
        controller.emit({
            var unknown = Self.failed("")
            unknown.status = "unknown"
            return unknown
        }())
        #expect(store.refusal == nil)
        #expect(store.unavailableMethods.isEmpty)
        #expect(log.events.isEmpty)
        #expect(store.display.isFailed)
    }

    // MARK: paid

    @Test func paidShowsTheSuccessOnceAndStartsTheBalanceRefresh() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open())
        store.setVisible(true, .invoice)
        var confirming = Self.open(status: "confirming")
        confirming.confirmations = 0
        controller.emit(confirming)
        #expect(!store.purchaseSucceeded)

        controller.emit(Self.paid())
        #expect(store.purchaseSucceeded)
        #expect(store.paidSequence == 1)
        #expect(store.paidWhere == .invoice)
        // the surface's success state replaces the invoice
        #expect(!store.isPresented)
        #expect(!store.hasInvoiceInProgress)
        #expect(log.events == [
            CryptoPurchaseEvent(kind: .started, method: .xmr, plan: "yearly", priceUsd: 40),
            CryptoPurchaseEvent(kind: .completed, method: .xmr, plan: "yearly", priceUsd: 40),
        ])

        // the same answer again is not a second purchase
        controller.emit(Self.paid())
        #expect(store.paidSequence == 1)
        #expect(log.events.count == 2)

        // the sheet closed: the next one starts clean
        store.resetPurchaseState()
        #expect(!store.purchaseSucceeded)
    }

    @Test func paidWhileOnlyTheAccountRowShowedItGoesToTheAccountScreen() {
        controller.saved = Self.open(status: "confirming")
        let store = makeStore()
        #expect(store.resume())
        #expect(store.hasInvoiceInProgress)
        #expect(!store.isPresented)
        store.setAppActive(true)
        store.setVisible(true, .accountRow)
        controller.emit(Self.paid(Self.open(status: "confirming")))
        #expect(store.paidWhere == .accountRow)
        #expect(store.purchaseSucceeded)
        #expect(store.paidSequence == 1)
    }

    // MARK: closing

    @Test func closeKeepsTheInvoiceForLater() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open())
        store.closeInvoice()
        #expect(!store.isPresented)
        #expect(!controller.calls.contains("dismiss"))
        #expect(store.hasInvoiceInProgress)
        // the account row (or the next surface) shows it again
        store.presentInvoice()
        #expect(store.isPresented)
    }

    @Test func payAnotherWayDropsTheInvoiceAndGoesBackToCard() {
        let store = makeStore()
        store.choose(.xmr)
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open())
        controller.calls.removeAll()

        store.payAnotherWay()
        #expect(controller.calls == ["dismiss", "setPaymentMethod:card"])
        #expect(!store.isPresented)
        #expect(store.rememberedMethod == "card")
        #expect(store.methodRow(listed: ["card", "xmr"]).selected == .card)
        #expect(!store.hasInvoiceInProgress)
        #expect(log.events.last == CryptoPurchaseEvent(kind: .cancelled, method: .xmr, plan: "yearly", priceUsd: 40))
    }

    @Test func payAnotherWayAfterMoneyArrivedIsNotACancel() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open())
        var seen = Self.open(status: "seen")
        seen.remaining = "0.01"
        controller.emit(seen)
        store.payAnotherWay()
        #expect(log.events.map(\.kind) == [.started])
    }

    @Test func aCoinShowsTheInvoiceInProgressInsteadOfStartingAnother() {
        // one invoice at a time (CONTRACT §6.2.1): pending, seen, unpolled
        var seen = Self.open(status: "seen")
        seen.remaining = "0.01"
        var unpolled = Self.open()
        unpolled.status = ""
        for inProgress in [Self.open(), seen, unpolled] {
            let controller = FakeCryptoInvoiceController()
            controller.saved = inProgress
            let store = CryptoInvoiceStore(controller: controller, catalog: CryptoPaymentRulesTests.catalog, recordEvent: { _ in })
            #expect(store.resume())
            #expect(!store.isPresented)

            // another coin, or the same one, from the plans
            store.startInvoice(.zec, plan: "yearly", storefrontCountry: nil)
            #expect(!controller.calls.contains { $0.hasPrefix("startInvoice") }, "\(inProgress.status)")
            #expect(store.isPresented)
            #expect(store.snapshot.asset == "xmr")
        }
    }

    @Test func afterPayAnotherWayACoinStartsANewInvoice() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open())
        store.closeInvoice()
        store.startInvoice(.zec, plan: "yearly", storefrontCountry: nil)
        #expect(controller.calls.filter { $0.hasPrefix("startInvoice") } == ["startInvoice:xmr:yearly::"])
        #expect(store.isPresented)

        store.payAnotherWay()
        store.startInvoice(.zec, plan: "yearly", storefrontCountry: nil)
        #expect(controller.calls.last == "startInvoice:zec:yearly::")
    }

    @Test func aPaidInvoiceDoesNotHoldBackTheNextPurchase() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open())
        controller.emit(Self.paid())
        store.startInvoice(.zec, plan: "yearly", storefrontCountry: nil)
        #expect(controller.calls.last == "startInvoice:zec:yearly::")
    }

    @Test func payAnotherWayBeforeTheFirstPollIsNotACancel() {
        // a resumed invoice may be paid until its first poll says otherwise
        controller.saved = {
            var unpolled = Self.open()
            unpolled.status = ""
            return unpolled
        }()
        let store = makeStore()
        #expect(store.resume())
        store.payAnotherWay()
        #expect(log.events.isEmpty)
        #expect(controller.calls.contains("dismiss"))
    }

    @Test func aRequoteGoesToTheSdk() {
        let store = makeStore()
        store.startInvoice(.xmr, plan: "yearly", storefrontCountry: nil)
        controller.emit(Self.open(status: "expired"))
        store.requote()
        #expect(controller.calls.last == "requote")
    }

    // MARK: resuming

    @Test func resumeFindsTheSavedInvoiceWithoutShowingIt() {
        controller.saved = Self.open()
        let store = makeStore()
        #expect(store.resume())
        #expect(store.hasInvoiceInProgress)
        #expect(!store.isPresented)
        // a resumed invoice was started before: no second start event
        #expect(log.events.isEmpty)
        store.presentInvoice()
        #expect(store.isPresented)
    }

    @Test func nothingSavedNothingToShow() {
        let store = makeStore()
        #expect(!store.resume())
        #expect(!store.hasInvoiceInProgress)
        store.presentInvoice()
        #expect(!store.isPresented)
    }

    // MARK: running

    @Test func theControllerRunsOnlyWhileShownAndTheAppIsActive() {
        let store = makeStore()
        store.setVisible(true, .invoice)
        // the window is hidden or the app inactive: nothing runs
        #expect(controller.calls.isEmpty)
        #expect(!store.isRunning)

        store.setAppActive(true)
        #expect(controller.calls == ["start"])

        store.setAppActive(false)
        #expect(controller.calls == ["start", "stop"])

        store.setAppActive(true)
        store.setVisible(false, .invoice)
        #expect(controller.calls == ["start", "stop", "start", "stop"])

        // the account screen's row keeps its status current too
        store.setVisible(true, .accountRow)
        #expect(controller.calls.last == "start")
        store.setVisible(false, .accountRow)
        #expect(controller.calls.last == "stop")
        #expect(!store.isRunning)
    }

    @Test func aViewThatAppearsBeforeTheOneItReplacesKeepsItRunning() {
        let store = makeStore()
        store.setAppActive(true)
        store.setVisible(true, .invoice)
        // the next surface's invoice appears, then the last one disappears
        store.setVisible(true, .invoice)
        store.setVisible(false, .invoice)
        #expect(store.isRunning)
        #expect(controller.calls == ["start"])
        store.setVisible(false, .invoice)
        #expect(!store.isRunning)
        // more disappearances than appearances do not go negative
        store.setVisible(false, .invoice)
        store.setVisible(true, .invoice)
        #expect(store.isRunning)
    }
}
