//
//  CryptoPaymentSdkTests.swift
//  networkTests
//
//  The direct-download build's crypto payments against the real SDK
//  (mmm/ZCASH-CONTRACT.md §4.2–§4.4): the Swift values match the SDK's
//  constants, the URI gate is the SDK's CheckCryptoPaymentUri with its
//  arguments in the right order, the method row's lists come from the SDK's
//  PaymentMethods over the balance's crypto_assets, the balance's crypto_term
//  and store family are read, and the invoice state maps field for field.
//  No network: the SDK's pure helpers and gomobile values only.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct CryptoPaymentSdkTests {

    private let catalog = SdkCryptoPaymentCatalog()

    private static let xmrAddress = CryptoPaymentRulesTests.xmrAddress
    private static let zecAddress = "u1qpatys4zruk99pg59gcscrt7y6akvl9vrhcfyhm9yxvxz7h87q6n8cgrzzpe9zru68uq39uhmlpp5uefxu0su5uqyqfe5zp3tycn0ecl"

    // MARK: the SDK's values

    @Test func theMethodsAreTheSdks() {
        #expect(PaymentMethod.card.rawValue == SdkPaymentMethodCard)
        #expect(PaymentMethod.usdcSolana.rawValue == SdkCryptoAssetUsdcSolana)
        #expect(PaymentMethod.zec.rawValue == SdkCryptoAssetZec)
        #expect(PaymentMethod.xmr.rawValue == SdkCryptoAssetXmr)
        #expect(PaymentMethod.card.eventStore == SdkEventStoreStripe)
        #expect(PaymentMethod.usdcSolana.eventStore == SdkEventStoreSolana)
        #expect(PaymentMethod.zec.eventStore == SdkEventStoreZcash)
        #expect(PaymentMethod.xmr.eventStore == SdkEventStoreMonero)
        #expect(PaymentMethodRules.planYearly == SdkPlanYearly)
        #expect(PaymentMethodRules.planYearlyOnboarding == SdkPlanYearlyOnboarding)
        #expect(PaymentMethodRules.planMonthly == SdkPlanMonthly)
    }

    @Test func theStatesAndCodesAreTheSdks() {
        #expect(CryptoInvoiceSnapshot.Phase.none.rawValue == SdkCryptoInvoicePhaseNone)
        #expect(CryptoInvoiceSnapshot.Phase.starting.rawValue == SdkCryptoInvoicePhaseStarting)
        #expect(CryptoInvoiceSnapshot.Phase.open.rawValue == SdkCryptoInvoicePhaseOpen)
        #expect(CryptoInvoiceSnapshot.Phase.paid.rawValue == SdkCryptoInvoicePhasePaid)
        #expect(CryptoInvoiceSnapshot.Phase.failed.rawValue == SdkCryptoInvoicePhaseFailed)
        #expect(CryptoPaymentStatus.pending == SdkCryptoPaymentStatusPending)
        #expect(CryptoPaymentStatus.seen == SdkCryptoPaymentStatusSeen)
        #expect(CryptoPaymentStatus.confirming == SdkCryptoPaymentStatusConfirming)
        #expect(CryptoPaymentStatus.paid == SdkCryptoPaymentStatusPaid)
        #expect(CryptoPaymentStatus.expired == SdkCryptoPaymentStatusExpired)
        #expect(CryptoPaymentStatus.review == SdkCryptoPaymentStatusReview)
        #expect(CryptoPaymentStatus.unknown == SdkCryptoPaymentStatusUnknown)
        #expect(CryptoPurchaseErrorCode.assetUnavailable == SdkPurchaseErrorCodeAssetUnavailable)
        #expect(CryptoPurchaseErrorCode.quoteExpired == SdkPurchaseErrorCodeQuoteExpired)
        #expect(CryptoPurchaseErrorCode.underpaid == SdkPurchaseErrorCodeUnderpaid)
        #expect(CryptoPurchaseErrorCode.guestSignInRequired == SdkPurchaseErrorCodeGuestSignInRequired)
        #expect(subscriptionStoreIsCrypto(SdkSubscriptionStoreCrypto))
    }

    // MARK: the URI gate

    @Test func theUriGateIsTheSdksCheckWithTheAddressOnScreen() {
        let uri = CryptoPaymentRulesTests.xmrUri
        #expect(catalog.checkPaymentUri(asset: "xmr", uri: uri, address: Self.xmrAddress))
        // another address than the one on screen
        #expect(!catalog.checkPaymentUri(asset: "xmr", uri: uri, address: Self.zecAddress))
        // another coin's scheme
        #expect(!catalog.checkPaymentUri(asset: "zec", uri: uri, address: Self.xmrAddress))
        // a Zcash uri that would also pay a second recipient
        let zcash = "zcash:\(Self.zecAddress)?amount=0.5&message=URnetwork%20Pro%20yearly"
        #expect(catalog.checkPaymentUri(asset: "zec", uri: zcash, address: Self.zecAddress))
        #expect(!catalog.checkPaymentUri(asset: "zec", uri: zcash + "&address.1=\(Self.zecAddress)&amount.1=1", address: Self.zecAddress))
    }

    @Test func theInvoiceShowsTheQrOnlyWhenTheSdkPassesTheUri() {
        let open = CryptoPaymentRulesTests.openXmr()
        #expect(CryptoInvoiceDisplay(open, catalog: catalog).paymentUri == CryptoPaymentRulesTests.xmrUri)

        var elsewhere = open
        elsewhere.uri = "monero:\(Self.xmrAddress.dropLast())X?tx_amount=0.072387"
        #expect(CryptoInvoiceDisplay(elsewhere, catalog: catalog).paymentUri == nil)

        var wrongScheme = open
        wrongScheme.uri = "bitcoin:\(Self.xmrAddress)?amount=1"
        #expect(CryptoInvoiceDisplay(wrongScheme, catalog: catalog).paymentUri == nil)
    }

    @Test func theTickersWalletsAndMonthlyRuleAreTheSdks() {
        #expect(catalog.ticker(asset: "usdc_solana") == "USDC")
        #expect(catalog.ticker(asset: "zec") == "ZEC")
        #expect(catalog.ticker(asset: "xmr") == "XMR")
        #expect(catalog.walletSuggestions(asset: "xmr") == ["Cake", "Feather", "Monerujo", "Stack", "Unstoppable"])
        #expect(catalog.walletSuggestions(asset: "zec") == ["Zodl", "Cake", "Zingo", "Zkool", "Vizor"])
        #expect(catalog.walletSuggestions(asset: "usdc_solana") == ["Phantom", "Solflare"])
        #expect(catalog.walletSuggestions(asset: "card").isEmpty)
        #expect(!catalog.allowsPlan(method: "xmr", plan: "monthly"))
        #expect(catalog.allowsPlan(method: "xmr", plan: "yearly"))
        #expect(catalog.allowsPlan(method: "card", plan: "monthly"))
    }

    // MARK: the balance

    private static func asset(_ asset: String, plans: [String], items: [String] = []) -> SdkCryptoPaymentAsset {
        let value = SdkCryptoPaymentAsset()
        value.asset = asset
        value.plans = CryptoPaymentSdk.stringList(plans)
        value.items = CryptoPaymentSdk.stringList(items)
        value.confirmationsRequired = 1
        value.quoteTtlSeconds = 1800
        return value
    }

    private static func assets(_ values: [SdkCryptoPaymentAsset]) -> SdkCryptoPaymentAssetList? {
        let list = SdkNewCryptoPaymentAssetList()
        for value in values {
            list?.add(value)
        }
        return list
    }

    @Test func theMethodsComeFromTheSdkPerPlanACoinBuys() {
        let methods = CryptoPaymentSdk.methodsByPlan(Self.assets([
            // the server's order means nothing; monthly is never sold
            Self.asset("xmr", plans: ["yearly", "monthly"]),
            Self.asset("usdc_solana", plans: ["yearly", "yearly_onboarding"], items: ["data_1tib"]),
        ]))
        #expect(methods["yearly"] == ["card", "usdc_solana", "xmr"])
        #expect(methods["yearly_onboarding"] == ["card", "usdc_solana"])
        // no assets (an older server, every coin off): Card alone, no row
        let none = CryptoPaymentSdk.methodsByPlan(nil)
        #expect(none["yearly"] == ["card"])
        #expect(PaymentMethodRules.methods(none["yearly"] ?? []) == [.card])
    }

    private func makeViewModel() -> SubscriptionBalanceViewModel {
        SubscriptionBalanceViewModel(
            urApiService: MockUrApiService(),
            isPro: true,
            refreshJwt: {},
            purchaseConfirmation: IdlePurchaseConfirmation()
        )
    }

    @Test func theBalanceCarriesTheCoinsTheTermAndTheStoresFamily() throws {
        let result = SdkSubscriptionBalanceResult()
        result.cryptoAssets = Self.assets([
            Self.asset("zec", plans: ["yearly", "yearly_onboarding"]),
            Self.asset("xmr", plans: ["yearly"]),
        ])
        let term = SdkCryptoTerm()
        term.market = "monero"
        term.termEndTime = "2027-10-20T18:00:00Z"
        term.graceEndTime = "2027-11-19T18:00:00Z"
        result.cryptoTerm = term
        let subscription = SdkSubscription()
        subscription.store = "monero"
        subscription.plan = "yearly"
        result.currentSubscription = subscription

        let viewModel = makeViewModel()
        viewModel.applyCryptoPayments(result)
        #expect(viewModel.cryptoPaymentMethods(offerActive: false) == ["card", "zec", "xmr"])
        #expect(viewModel.cryptoPaymentMethods(offerActive: true) == ["card", "zec"])
        let parsed = try #require(viewModel.cryptoTerm)
        #expect(parsed == CryptoTerm(market: "monero", termEndTime: "2027-10-20T18:00:00Z", graceEndTime: "2027-11-19T18:00:00Z"))
        #expect(parsed.graceEnd == parseRfc3339("2027-11-19T18:00:00Z"))
        #expect(viewModel.currentSubscriptionStoreClass == "crypto")

        // the next balance without them clears them
        viewModel.applyCryptoPayments(SdkSubscriptionBalanceResult())
        #expect(viewModel.cryptoPaymentMethods(offerActive: false) == ["card"])
        #expect(viewModel.cryptoTerm == nil)
        #expect(viewModel.currentSubscriptionStoreClass == "")
    }

    @Test func everyOneTimeCryptoMarketIsTheCryptoFamily() {
        for market in ["solana", "monero", "zcash"] {
            #expect(CryptoPaymentSdk.storeClass(market) == "crypto")
        }
        #expect(CryptoPaymentSdk.storeClass("stripe") == "stripe")
        #expect(CryptoPaymentSdk.storeClass("") == "")
    }

    @Test func theRenewalNoticeIsTheSdksRule() {
        // from the end of the paid term until the grace ends, never before
        let now = Date()
        let formatter = ISO8601DateFormatter()
        func term(_ termEnd: TimeInterval, _ graceEnd: TimeInterval) -> CryptoTerm {
            CryptoTerm(
                market: "zcash",
                termEndTime: formatter.string(from: now.addingTimeInterval(termEnd)),
                graceEndTime: formatter.string(from: now.addingTimeInterval(graceEnd))
            )
        }
        #expect(!CryptoPaymentSdk.termNoticeDue(term(3600, 7200)))
        #expect(CryptoPaymentSdk.termNoticeDue(term(-3600, 3600)))
        #expect(!CryptoPaymentSdk.termNoticeDue(term(-7200, -3600)))
        // times that do not parse show nothing
        #expect(!CryptoPaymentSdk.termNoticeDue(CryptoTerm(market: "monero", termEndTime: "", graceEndTime: "")))
    }

    // MARK: the invoice state

    @Test func theInvoiceStateMapsFieldForField() {
        let state = SdkCryptoInvoiceState()
        state.phase = "open"
        state.intentId = "0b6f"
        state.asset = "usdc_solana"
        state.plan = "yearly_onboarding"
        state.itemId = ""
        state.delivery = "account"
        state.networkName = "alice"
        state.address = "7xKX"
        state.amount = "29.000123"
        state.amountAtomic = "29000123"
        state.ticker = "USDC"
        state.uri = "solana:7xKX?amount=29.000123"
        state.memo = "8Xref"
        state.priceUsd = 29
        state.rateUsd = 1
        state.expiresAt = "2026-10-20T18:30:00Z"
        state.secondsLeft = 3599
        state.status = "seen"
        state.reviewReason = "extra"
        state.received = "10"
        state.remaining = "19.000123"
        state.confirmations = 2
        state.confirmationsRequired = 3
        state.balanceCode = "code"
        state.refreshing = true
        state.errorCode = "asset_unavailable"
        state.errorMessage = "off"

        var expected = CryptoInvoiceSnapshot()
        expected.phaseName = "open"
        expected.intentId = "0b6f"
        expected.asset = "usdc_solana"
        expected.plan = "yearly_onboarding"
        expected.delivery = "account"
        expected.networkName = "alice"
        expected.address = "7xKX"
        expected.amount = "29.000123"
        expected.amountAtomic = "29000123"
        expected.ticker = "USDC"
        expected.uri = "solana:7xKX?amount=29.000123"
        expected.memo = "8Xref"
        expected.priceUsd = 29
        expected.rateUsd = 1
        expected.expiresAt = "2026-10-20T18:30:00Z"
        expected.secondsLeft = 3599
        expected.status = "seen"
        expected.reviewReason = "extra"
        expected.received = "10"
        expected.remaining = "19.000123"
        expected.confirmations = 2
        expected.confirmationsRequired = 3
        expected.balanceCode = "code"
        expected.refreshing = true
        expected.errorCode = "asset_unavailable"
        expected.errorMessage = "off"

        #expect(CryptoInvoiceSnapshot(state) == expected)
        #expect(CryptoInvoiceSnapshot(nil) == CryptoInvoiceSnapshot())
    }

    @Test func aControllerTheSdkCouldNotMakeFailsTheStartAtOnce() {
        let controller = SdkCryptoInvoiceController(controller: nil)
        var changes = 0
        controller.onChange = { changes += 1 }
        #expect(controller.state.phase == .none)
        #expect(!controller.resume())
        #expect(controller.paymentMethod == "card")
        controller.startInvoice(asset: "xmr", plan: "yearly", itemId: "", storefrontCountry: "")
        #expect(changes == 1)
        #expect(controller.state.phase == .failed)
        #expect(controller.state.errorCode == "start_failed")
        controller.dismiss()
        #expect(controller.state.phase == .none)
    }

    @Test func theRealControllerRemembersTheMethodInTheLocalStateDirectory() throws {
        // a network space whose api reaches nothing; no call is made here
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "crypto-invoice-test-" + UUID().uuidString,
            isDirectory: true
        )
        let storage = directory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let spaceManager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            spaceManager.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try #require(SdkNewNetworkSpaceKey("crypto-invoice.example", "test"))
        let space = try #require(spaceManager.updateNetworkSpaceValues(key, values: values))
        let api = try #require(space.getApi())

        do {
            let controller = SdkCryptoInvoiceController(controller: SdkNewCryptoInvoiceViewController(api, storage.path))
            #expect(controller.state.phase == .none)
            // nothing saved for this (signed-out) network
            #expect(!controller.resume())
            #expect(controller.paymentMethod == "")
            controller.setPaymentMethod("xmr")
            // anything but a method is ignored
            controller.setPaymentMethod("doge")
            #expect(controller.paymentMethod == "xmr")
        }

        // the next launch's controller reads it back, from a 0600 file in the
        // directory a sign-out clears
        let next = SdkCryptoInvoiceController(controller: SdkNewCryptoInvoiceViewController(api, storage.path))
        #expect(next.paymentMethod == "xmr")
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.appendingPathComponent(".payment_method").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

/// A purchase confirmation that never runs (the balance tests read no states).
@MainActor
private final class IdlePurchaseConfirmation: PurchaseConfirming {
    var onStateChanged: ((String) -> Void)?
    func start() {}
    func stop() {}
    func setForeground(_ foreground: Bool) {}
    func startPurchaseConfirmation() {}
}
