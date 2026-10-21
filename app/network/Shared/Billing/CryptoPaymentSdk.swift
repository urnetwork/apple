//
//  CryptoPaymentSdk.swift
//  URnetwork
//
//  The SDK side of the crypto payments (mmm/ZCASH-CONTRACT.md §4.2–§4.4):
//  the gomobile CryptoInvoiceViewController behind CryptoInvoiceControlling,
//  and the SDK's pure helpers behind CryptoPaymentCatalog. Its listener fires
//  on a Go thread; changes are hopped to the main actor in order, like
//  SdkPurchaseConfirmation's.
//
//  No strings and no views. Only the direct-download build creates a
//  controller (MainView); the helpers are pure and tested in both builds.
//

import Foundation
import URnetworkSdk

// MARK: - the SDK's pure helpers

/// The SDK's CheckCryptoPaymentUri, CryptoAssetTicker, CryptoWalletSuggestions
/// and PaymentMethodAllowsPlan.
struct SdkCryptoPaymentCatalog: CryptoPaymentCatalog {

    func checkPaymentUri(asset: String, uri: String, address: String) -> Bool {
        SdkCheckCryptoPaymentUri(asset, uri, address)
    }

    func ticker(asset: String) -> String {
        SdkCryptoAssetTicker(asset)
    }

    func walletSuggestions(asset: String) -> [String] {
        CryptoPaymentSdk.strings(SdkCryptoWalletSuggestions(asset))
    }

    func allowsPlan(method: String, plan: String) -> Bool {
        SdkPaymentMethodAllowsPlan(method, plan)
    }
}

enum CryptoPaymentSdk {

    /// The plans a coin can buy on a plan surface: yearly, and yearly with the
    /// welcome offer.
    static let plans = [PaymentMethodRules.planYearly, PaymentMethodRules.planYearlyOnboarding]

    /// The SDK's PaymentMethods for each plan a coin can buy, from the
    /// balance's crypto_assets (CONTRACT §2.2): `card` first, then each listed
    /// coin that sells the plan. No assets (an older server, or every coin
    /// switched off) lists Card alone.
    static func methodsByPlan(_ assets: SdkCryptoPaymentAssetList?) -> [String: [String]] {
        var methods: [String: [String]] = [:]
        for plan in plans {
            methods[plan] = strings(SdkPaymentMethods(assets, stringList([plan])))
        }
        return methods
    }

    /// The balance's crypto_term, when the server sent one.
    static func term(_ term: SdkCryptoTerm?) -> CryptoTerm? {
        guard let term else {
            return nil
        }
        return CryptoTerm(market: term.market, termEndTime: term.termEndTime, graceEndTime: term.graceEndTime)
    }

    /// The SDK's CryptoTermNoticeDue, now: the paid term has ended and its
    /// grace has not (term_end_time <= now < grace_end_time), and never before.
    static func termNoticeDue(_ term: CryptoTerm) -> Bool {
        let sdkTerm = SdkCryptoTerm()
        sdkTerm.market = term.market
        sdkTerm.termEndTime = term.termEndTime
        sdkTerm.graceEndTime = term.graceEndTime
        return SdkCryptoTermNoticeDue(sdkTerm)
    }

    /// The SDK's ClassifySubscriptionStore of the current subscription's store.
    static func storeClass(_ store: String) -> String {
        SdkClassifySubscriptionStore(store)
    }

    static func strings(_ list: SdkStringList?) -> [String] {
        guard let list else {
            return []
        }
        return (0..<list.len()).map { list.get($0) }
    }

    static func stringList(_ values: [String]) -> SdkStringList? {
        let list = SdkNewStringList()
        for value in values {
            list?.add(value)
        }
        return list
    }
}

// MARK: - the invoice state

extension CryptoInvoiceSnapshot {

    /// The SDK state as plain values; none for no state.
    init(_ state: SdkCryptoInvoiceState?) {
        self.init()
        guard let state else {
            return
        }
        phaseName = state.phase
        intentId = state.intentId
        asset = state.asset
        plan = state.plan
        itemId = state.itemId
        delivery = state.delivery
        networkName = state.networkName
        address = state.address
        amount = state.amount
        amountAtomic = state.amountAtomic
        ticker = state.ticker
        uri = state.uri
        memo = state.memo
        priceUsd = state.priceUsd
        rateUsd = state.rateUsd
        expiresAt = state.expiresAt
        secondsLeft = state.secondsLeft
        status = state.status
        reviewReason = state.reviewReason
        received = state.received
        remaining = state.remaining
        confirmations = state.confirmations
        confirmationsRequired = state.confirmationsRequired
        balanceCode = state.balanceCode
        refreshing = state.refreshing
        errorCode = state.errorCode
        errorMessage = state.errorMessage
    }
}

// MARK: - the controller

/// The SDK's CryptoInvoiceViewController, closed with this object.
///
/// The device opens it (OpenCryptoInvoiceViewController): on the device's
/// api, with the invoice and the payment method saved in the network space's
/// local-state directory, which a sign-out clears, and closed with the device.
/// Opening and closing it takes no device state lock (no rpc to the tunnel),
/// so it is safe on the main actor.
@MainActor
final class SdkCryptoInvoiceController: CryptoInvoiceControlling {

    var onChange: (() -> Void)?

    private let controller: SdkCryptoInvoiceViewController?
    /// The device that opened the controller, which closes it.
    private let device: SdkDeviceRemote?
    private var listenerSub: SdkSubProtocol?
    /// With no controller (the SDK could not make one) a start fails at once.
    private var localFailure: CryptoInvoiceSnapshot?

    convenience init(device: SdkDeviceRemote) {
        self.init(controller: device.openCryptoInvoiceViewController(), device: device)
    }

    init(controller: SdkCryptoInvoiceViewController?, device: SdkDeviceRemote? = nil) {
        self.controller = controller
        self.device = device
        listenerSub = controller?.add(CryptoInvoiceListener { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onChange?()
                }
            }
        })
    }

    deinit {
        listenerSub?.close()
        if let controller {
            if let device {
                // the manager's CloseViewController: Close, and forget it
                device.close(controller)
            } else {
                controller.close()
            }
        }
    }

    var state: CryptoInvoiceSnapshot {
        if let localFailure {
            return localFailure
        }
        return CryptoInvoiceSnapshot(controller?.getState())
    }

    func start() {
        controller?.start()
    }

    func stop() {
        controller?.stop()
    }

    func startInvoice(asset: String, plan: String, itemId: String, storefrontCountry: String) {
        guard let controller else {
            var failure = CryptoInvoiceSnapshot()
            failure.phaseName = CryptoInvoiceSnapshot.Phase.failed.rawValue
            failure.asset = asset
            failure.plan = plan
            failure.errorCode = "start_failed"
            localFailure = failure
            onChange?()
            return
        }
        localFailure = nil
        controller.startInvoice(asset, plan: plan, itemId: itemId, storefrontCountry: storefrontCountry)
    }

    func resume() -> Bool {
        controller?.resume() ?? false
    }

    func requote() {
        controller?.requote()
    }

    func dismiss() {
        localFailure = nil
        controller?.dismiss()
    }

    var paymentMethod: String {
        controller?.getPaymentMethod() ?? PaymentMethod.card.rawValue
    }

    func setPaymentMethod(_ method: String) {
        controller?.setPaymentMethod(method)
    }
}

private final class CryptoInvoiceListener: NSObject, SdkCryptoInvoiceListenerProtocol {
    private let callback: () -> Void

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func cryptoInvoiceChanged() {
        callback()
    }
}

// MARK: - the store over the SDK

extension CryptoInvoiceStore {

    /// The store over the device's controller, with the events through ClientEvents.
    convenience init(device: SdkDeviceRemote) {
        self.init(
            controller: SdkCryptoInvoiceController(device: device),
            catalog: SdkCryptoPaymentCatalog(),
            recordEvent: CryptoInvoiceStore.recordWithClientEvents
        )
    }

    /// The purchase events with the method's store (CONTRACT §6.1), in USD.
    static func recordWithClientEvents(_ event: CryptoPurchaseEvent) {
        let events = ClientEvents.shared
        let store = event.method.eventStore
        let product = event.method.eventProduct
        switch event.kind {
        case .started:
            events.purchaseStarted(store: store, product: product, plan: event.plan, trial: false, price: event.priceUsd, currency: "USD")
        case .completed:
            events.purchaseCompleted(store: store, product: product, plan: event.plan, trial: false, price: event.priceUsd, currency: "USD")
        case .cancelled:
            events.purchaseCancelled(store: store, product: product, plan: event.plan, trial: false, price: event.priceUsd, currency: "USD")
        case .failed(let errorClass):
            events.purchaseFailed(store: store, product: product, plan: event.plan, trial: false, price: event.priceUsd, currency: "USD", errorClass: errorClass)
        }
    }
}
