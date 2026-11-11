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

/// The SDK's CheckCryptoPaymentUri, CryptoAssetTicker, CryptoWalletSuggestions,
/// PaymentMethodAllowsPlan, CryptoPaymentUriScheme and CryptoPaymentTabId.
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

    func uriScheme(asset: String) -> String {
        SdkCryptoPaymentUriScheme(asset)
    }

    func tabId(asset: String) -> String {
        SdkCryptoPaymentTabId(asset)
    }
}

extension PaymentMethod {

    /// The store the offer and purchase events name (CONTRACT §6.1): Stripe
    /// for Card, the coin's market otherwise (the SDK's CryptoAssetMarket:
    /// solana, zcash, monero, bittensor, bitcoin, ethereum).
    var eventStore: String {
        guard let asset else {
            return SdkEventStoreStripe
        }
        return SdkCryptoAssetMarket(asset)
    }

    /// The purchase events' product: Pro for Card, and for a coin its year of
    /// Pro by its ticker (the SDK's CryptoAssetTicker), as Android names them:
    /// pro_yearly_usdc, pro_yearly_zec, pro_yearly_xmr, pro_yearly_tao,
    /// pro_yearly_btc, pro_yearly_eth, pro_yearly_sol.
    var eventProduct: String {
        guard let asset else {
            return "pro"
        }
        return "pro_yearly_" + SdkCryptoAssetTicker(asset).lowercased()
    }

    /// A coin's label in English and its string id in the shared localizations
    /// (the SDK's CryptoAssetLabel and CryptoAssetLabelKey), which the views
    /// look the name up by; "" for Card, whose name is the row's own.
    var sdkLabel: String {
        asset.map { SdkCryptoAssetLabel($0) } ?? ""
    }

    var sdkLabelKey: String {
        asset.map { SdkCryptoAssetLabelKey($0) } ?? ""
    }
}

enum CryptoPaymentSdk {

    /// The plans a coin can buy on a plan surface: yearly, and yearly with the
    /// welcome offer.
    static let plans = [PaymentMethodRules.planYearly, PaymentMethodRules.planYearlyOnboarding]

    /// The SDK's coin tabs (CryptoPaymentTabs) for each plan a coin can buy,
    /// from the balance's crypto_assets (CONTRACT §2.2), which names only the
    /// coins payable now, so there is no list of unavailable ones: USDC on
    /// Solana, Zcash, Monero and More coins, each coin with whether it sells
    /// the plan. No assets (an older server, or every coin switched off), or
    /// no coin that sells the plan, lists no tab: Card alone, no row.
    static func tabsByPlan(_ assets: SdkCryptoPaymentAssetList?) -> [String: [CryptoPayTab]] {
        var byPlan: [String: [CryptoPayTab]] = [:]
        for plan in plans {
            byPlan[plan] = tabs(SdkCryptoPaymentTabs(assets, nil, stringList([plan])))
        }
        return byPlan
    }

    /// The asset catalog image of a coin's mark (the SDK's CryptoIconKey*:
    /// coin_tao is coin.tao, a template image), nil for a mark this app does
    /// not bundle: USDC, Zcash and Monero have none, and their tabs show their
    /// names alone.
    static func markImageName(_ iconKey: String) -> String? {
        switch iconKey {
        case SdkCryptoIconKeyTao:
            return "coin.tao"
        case SdkCryptoIconKeyBtc:
            return "coin.btc"
        case SdkCryptoIconKeyEth:
            return "coin.eth"
        case SdkCryptoIconKeySol:
            return "coin.sol"
        default:
            return nil
        }
    }

    /// The SDK's tabs as plain values, in their order.
    static func tabs(_ list: SdkCryptoPaymentTabList?) -> [CryptoPayTab] {
        guard let list else {
            return []
        }
        var tabs: [CryptoPayTab] = []
        for i in 0..<list.len() {
            guard let tab = list.get(i) else {
                continue
            }
            var coins: [CryptoPayCoin] = []
            if let coinList = tab.coins {
                for j in 0..<coinList.len() {
                    guard let coin = coinList.get(j) else {
                        continue
                    }
                    coins.append(CryptoPayCoin(
                        asset: coin.asset,
                        label: coin.label,
                        labelKey: coin.labelKey,
                        iconKey: coin.iconKey,
                        available: coin.available
                    ))
                }
            }
            tabs.append(CryptoPayTab(
                id: tab.id_,
                label: tab.label,
                labelKey: tab.labelKey,
                iconKeys: strings(tab.iconKeys),
                coins: coins,
                available: tab.available
            ))
        }
        return tabs
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
        qrText = state.qrText
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
