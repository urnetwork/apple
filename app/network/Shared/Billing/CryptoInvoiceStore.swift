//
//  CryptoInvoiceStore.swift
//  URnetwork
//
//  The direct-download build's crypto invoice, for its billing surfaces: the
//  SDK's CryptoInvoiceViewController (CONTRACT §4.4) owns the quote, the
//  countdown, the requote, the status polling and the saved invoice; this
//  store relays its state to the main actor, remembers the per-device payment
//  method through it, and turns its transitions into what the surfaces do (the
//  invoice over the plans, the row's "temporarily unavailable", the existing
//  refusal handling, the add-sign-in sheet, the success state and the events).
//
//  The controller runs only while something shows the invoice (the invoice
//  itself, or the account screen's in-progress row) and the app is active:
//  Start() then, Stop() otherwise. Nothing polls in the background (§0.3).
//
//  No strings and no views: it compiles in both builds and is tested with a
//  fake controller. Only the direct-download build creates one (MainView).
//

import Foundation

/// The SDK's CryptoInvoiceViewController as the store drives it (a protocol
/// so the flow is tested with a fake). Changes are reported on the main actor.
@MainActor
protocol CryptoInvoiceControlling: AnyObject {
    /// Set by the store; called on the main actor whenever the state may have changed.
    var onChange: (() -> Void)? { get set }
    var state: CryptoInvoiceSnapshot { get }
    /// Visible: poll and tick.
    func start()
    /// Hidden: nothing runs.
    func stop()
    func startInvoice(asset: String, plan: String, itemId: String, storefrontCountry: String)
    /// The saved invoice of the signed-in network, if any.
    func resume() -> Bool
    func requote()
    /// "Pay another way" / close for good.
    func dismiss()
    /// The last method chosen on this device.
    var paymentMethod: String { get }
    func setPaymentMethod(_ method: String)
}

/// A purchase event of a crypto invoice (CONTRACT §6.1: the events carry the
/// method's store).
struct CryptoPurchaseEvent: Equatable {
    enum Kind: Equatable {
        case started
        case completed
        case cancelled
        case failed(errorClass: String)
    }

    var kind: Kind
    var method: PaymentMethod
    /// The plan as the events name it: yearly (the welcome offer's included).
    var plan: String
    /// The quote's USD price; -1 before the server quoted.
    var priceUsd: Double
}

@MainActor
final class CryptoInvoiceStore: ObservableObject {

    /// What shows the invoice (or its summary) right now.
    enum Viewer: Hashable {
        /// The invoice itself, over a billing surface.
        case invoice
        /// The account screen's in-progress row.
        case accountRow
    }

    /// The invoice turned paid while shown where.
    enum PaidWhere: Equatable {
        /// Over a billing surface: that surface shows its success state.
        case invoice
        /// Only the account screen's row was showing it: the account screen
        /// opens the upgrade sheet on its success state.
        case accountRow
    }

    @Published private(set) var snapshot = CryptoInvoiceSnapshot()
    /// The last method chosen on this device, as the SDK keeps it (a method
    /// the row does not list resolves to Card: PaymentMethodRules.selected).
    @Published private(set) var rememberedMethod: String
    /// The invoice shows over the surface that opened it.
    @Published private(set) var isPresented = false
    /// Coins whose last start failed with asset_unavailable.
    @Published private(set) var unavailableMethods: Set<PaymentMethod> = []
    /// The last start refusal the surface words itself (CheckoutRefusal).
    @Published private(set) var refusal: CryptoPurchaseRefusal?
    /// The invoice was paid: the surface shows the success state a card
    /// purchase shows, until it resets (the sheet closed).
    @Published private(set) var purchaseSucceeded = false
    private(set) var paidWhere: PaidWhere = .invoice
    /// Bumped once per paid invoice: MainView starts the confirmation poll
    /// (the balance refresh a card purchase starts).
    @Published private(set) var paidSequence = 0
    /// Bumped when the server refused the start because the network is a
    /// legacy guest: MainView marks it one, so the purchase's
    /// GuestPurchaseGate opens the add-sign-in sheet.
    @Published private(set) var guestSignInRequiredSequence = 0

    private let controller: CryptoInvoiceControlling
    private let catalog: CryptoPaymentCatalog
    private let recordEvent: @MainActor (CryptoPurchaseEvent) -> Void

    /// Counted, so a view that appears before the one it replaces disappears
    /// keeps the controller running.
    private var viewers: [Viewer: Int] = [:]
    private var appActive = false
    private var running = false
    /// A start this store made, until the controller opens it or refuses it.
    private var pendingStart: (method: PaymentMethod, plan: String)?
    private var startedIntents: Set<String> = []
    private var paidIntents: Set<String> = []

    init(
        controller: CryptoInvoiceControlling,
        catalog: CryptoPaymentCatalog,
        recordEvent: @escaping @MainActor (CryptoPurchaseEvent) -> Void
    ) {
        self.controller = controller
        self.catalog = catalog
        self.recordEvent = recordEvent
        rememberedMethod = controller.paymentMethod
        snapshot = controller.state
        controller.onChange = { [weak self] in
            self?.refresh()
        }
    }

    // MARK: the method row

    /// The row for a surface that lists `listed` (the SDK's PaymentMethods for
    /// the plan a coin would buy there).
    func methodRow(listed: [String]) -> PaymentMethodRowState {
        let methods = PaymentMethodRules.methods(listed)
        let selected = PaymentMethodRules.selected(remembered: rememberedMethod, methods: methods)
        return PaymentMethodRowState(
            methods: methods,
            selected: selected,
            selectedUnavailable: unavailableMethods.contains(selected),
            allowsMonthly: allowsMonthly(selected)
        )
    }

    /// The SDK's PaymentMethodAllowsPlan for monthly: Card only.
    func allowsMonthly(_ method: PaymentMethod) -> Bool {
        catalog.allowsPlan(method: method.rawValue, plan: PaymentMethodRules.planMonthly)
    }

    /// A pick on the row, remembered on this device.
    func choose(_ method: PaymentMethod) {
        controller.setPaymentMethod(method.rawValue)
        let remembered = controller.paymentMethod
        if rememberedMethod != remembered {
            rememberedMethod = remembered
        }
        if refusal != nil {
            refusal = nil
        }
    }

    // MARK: the invoice

    /// Starts an invoice for a coin's plan (yearly, or yearly_onboarding with
    /// the welcome offer) and shows it. Paying happens in a wallet outside the
    /// app, so unlike the store purchases the VPN stays as it is.
    func startInvoice(_ method: PaymentMethod, plan: String, storefrontCountry: String?) {
        guard let asset = method.asset else {
            return
        }
        if snapshot.isInProgress && snapshot.status != CryptoPaymentStatus.unknown {
            // one invoice at a time (CONTRACT §6.2.1): a new one would replace
            // the saved invoice, status token and all, and the app would lose
            // track of a payment the server still credits. "Pay another way"
            // is the way out.
            isPresented = true
            return
        }
        if refusal != nil {
            refusal = nil
        }
        unavailableMethods.remove(method)
        if purchaseSucceeded {
            purchaseSucceeded = false
        }
        pendingStart = (method, plan)
        isPresented = true
        controller.startInvoice(asset: asset, plan: plan, itemId: "", storefrontCountry: storefrontCountry ?? "")
        refresh()
    }

    /// The saved invoice of the signed-in network, if any (at launch, when the
    /// account screen appears, and when a billing surface opens).
    @discardableResult
    func resume() -> Bool {
        let found = controller.resume()
        refresh()
        return found
    }

    /// An invoice is open and not paid.
    var hasInvoiceInProgress: Bool {
        snapshot.isInProgress
    }

    /// What the invoice shows now (CONTRACT §6.2).
    var display: CryptoInvoiceDisplay {
        CryptoInvoiceDisplay(snapshot, catalog: catalog)
    }

    /// Shows the invoice in progress over the surface (the account screen's
    /// row, a billing surface that opens while one is in progress).
    func presentInvoice() {
        guard snapshot.isInProgress, !isPresented else {
            return
        }
        isPresented = true
    }

    /// Close: the invoice is kept (Resume and the account row bring it back).
    func closeInvoice() {
        if isPresented {
            isPresented = false
        }
    }

    /// "Pay another way": the invoice is dropped (or, once money arrived, only
    /// hidden: the SDK keeps it) and the row goes back to Card.
    func payAnotherWay() {
        let snapshot = controller.state
        if snapshot.isAwaitingPayment, let method = PaymentMethod(asset: snapshot.asset), !snapshot.intentId.isEmpty {
            recordEvent(CryptoPurchaseEvent(kind: .cancelled, method: method, plan: PaymentMethodRules.eventPlan(snapshot.plan), priceUsd: price(snapshot)))
        }
        pendingStart = nil
        controller.dismiss()
        isPresented = false
        choose(.card)
        refresh()
    }

    func requote() {
        controller.requote()
        refresh()
    }

    /// The surface closed: its success state describes one purchase.
    func resetPurchaseState() {
        if purchaseSucceeded {
            purchaseSucceeded = false
        }
        if refusal != nil {
            refusal = nil
        }
    }

    // MARK: running

    /// `viewer` shows the invoice (or stopped showing it).
    func setVisible(_ visible: Bool, _ viewer: Viewer) {
        let count = viewers[viewer] ?? 0
        viewers[viewer] = visible ? count + 1 : max(0, count - 1)
        updateRunning()
    }

    private func isVisible(_ viewer: Viewer) -> Bool {
        0 < (viewers[viewer] ?? 0)
    }

    /// The app is active with its window shown (presentationActive).
    func setAppActive(_ active: Bool) {
        appActive = active
        updateRunning()
    }

    private func updateRunning() {
        let shouldRun = appActive && (isVisible(.invoice) || isVisible(.accountRow))
        guard shouldRun != running else {
            return
        }
        running = shouldRun
        if shouldRun {
            controller.start()
        } else {
            controller.stop()
        }
    }

    /// Whether the controller polls and ticks now (for tests).
    var isRunning: Bool {
        running
    }

    // MARK: transitions

    private func price(_ snapshot: CryptoInvoiceSnapshot) -> Double {
        0 < snapshot.priceUsd ? snapshot.priceUsd : -1
    }

    private func refresh() {
        let next = controller.state
        if next != snapshot {
            snapshot = next
        }

        if let pending = pendingStart {
            switch next.phase {
            case .failed:
                pendingStart = nil
                startFailed(pending.method, plan: pending.plan, code: next.errorCode, message: next.errorMessage)
            case .open, .paid:
                pendingStart = nil
                unavailableMethods.remove(pending.method)
                // once per invoice: the server hands an open invoice for the
                // same coin and plan back as is
                if !next.intentId.isEmpty, !startedIntents.contains(next.intentId) {
                    startedIntents.insert(next.intentId)
                    let plan = PaymentMethodRules.eventPlan(next.plan.isEmpty ? pending.plan : next.plan)
                    recordEvent(CryptoPurchaseEvent(kind: .started, method: pending.method, plan: plan, priceUsd: price(next)))
                }
            case .none, .starting:
                break
            }
        }

        if next.isPaid, !next.intentId.isEmpty, !paidIntents.contains(next.intentId) {
            paidIntents.insert(next.intentId)
            if let method = PaymentMethod(asset: next.asset) {
                recordEvent(CryptoPurchaseEvent(kind: .completed, method: method, plan: PaymentMethodRules.eventPlan(next.plan), priceUsd: price(next)))
            }
            paidWhere = isPresented || isVisible(.invoice) ? .invoice : .accountRow
            isPresented = false
            purchaseSucceeded = true
            paidSequence += 1
        }
    }

    private func startFailed(_ method: PaymentMethod, plan: String, code: String, message: String) {
        recordEvent(CryptoPurchaseEvent(kind: .failed(errorClass: code.isEmpty ? "transport" : code), method: method, plan: PaymentMethodRules.eventPlan(plan), priceUsd: -1))
        isPresented = false
        switch code {
        case CryptoPurchaseErrorCode.assetUnavailable:
            // "Temporarily unavailable" under the row; the coin stays selectable
            unavailableMethods.insert(method)
        case CryptoPurchaseErrorCode.guestSignInRequired:
            guestSignInRequiredSequence += 1
        default:
            refusal = CryptoPurchaseRefusal(code: code, message: message)
        }
    }
}
