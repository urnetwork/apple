//
//  CryptoPaymentSdkTests.swift
//  networkTests
//
//  The direct-download build's crypto payments against the real SDK
//  (mmm/ZCASH-CONTRACT.md §4.2–§4.4): the Swift values match the SDK's
//  constants, the URI gate is the SDK's CheckCryptoPaymentUri with its
//  arguments in the right order, the method row's tabs come from the SDK's
//  CryptoPaymentTabs over the balance's crypto_assets, the events name the
//  SDK's markets, the balance's crypto_term and store family are read, and
//  the invoice state maps field for field.
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
        #expect(PaymentMethod.tao.rawValue == SdkCryptoAssetTao)
        #expect(PaymentMethod.btc.rawValue == SdkCryptoAssetBtc)
        #expect(PaymentMethod.eth.rawValue == SdkCryptoAssetEth)
        #expect(PaymentMethod.sol.rawValue == SdkCryptoAssetSol)
        #expect(PaymentMethodRules.planYearly == SdkPlanYearly)
        #expect(PaymentMethodRules.planYearlyOnboarding == SdkPlanYearlyOnboarding)
        #expect(PaymentMethodRules.planMonthly == SdkPlanMonthly)
    }

    @Test func theEventsNameTheCoinsMarketAndItsYearOfPro() {
        // the store is the coin's market, the SDK's CryptoAssetMarket
        #expect(PaymentMethod.card.eventStore == SdkEventStoreStripe)
        #expect(PaymentMethod.usdcSolana.eventStore == SdkEventStoreSolana)
        #expect(PaymentMethod.zec.eventStore == SdkEventStoreZcash)
        #expect(PaymentMethod.xmr.eventStore == SdkEventStoreMonero)
        #expect(PaymentMethod.tao.eventStore == SdkEventStoreBittensor)
        #expect(PaymentMethod.btc.eventStore == SdkEventStoreBitcoin)
        #expect(PaymentMethod.eth.eventStore == SdkEventStoreEthereum)
        #expect(PaymentMethod.sol.eventStore == SdkEventStoreSolana)
        #expect(PaymentMethod.card.eventStore == "stripe")
        #expect(PaymentMethod.tao.eventStore == "bittensor")
        // the product, by the coin's ticker, as Android names them
        #expect(PaymentMethod.card.eventProduct == "pro")
        #expect(PaymentMethod.usdcSolana.eventProduct == "pro_yearly_usdc")
        #expect(PaymentMethod.zec.eventProduct == "pro_yearly_zec")
        #expect(PaymentMethod.xmr.eventProduct == "pro_yearly_xmr")
        #expect(PaymentMethod.tao.eventProduct == "pro_yearly_tao")
        #expect(PaymentMethod.btc.eventProduct == "pro_yearly_btc")
        #expect(PaymentMethod.eth.eventProduct == "pro_yearly_eth")
        #expect(PaymentMethod.sol.eventProduct == "pro_yearly_sol")
    }

    @Test func theLabelsTabsSchemesAndMarksAreTheSdks() {
        // a coin's name is looked up by the SDK's key, with its English as the fallback
        #expect(PaymentMethod.usdcSolana.sdkLabelKey == "pay_method_usdc_solana")
        #expect(PaymentMethod.usdcSolana.sdkLabel == "USDC on Solana")
        #expect(PaymentMethod.tao.sdkLabelKey == "pay_method_tao")
        #expect(PaymentMethod.btc.sdkLabelKey == "pay_method_bitcoin")
        #expect(PaymentMethod.btc.sdkLabel == "Bitcoin")
        #expect(PaymentMethod.eth.sdkLabelKey == "pay_method_eth")
        #expect(PaymentMethod.sol.sdkLabelKey == "pay_method_sol")
        #expect(PaymentMethod.card.sdkLabelKey == "")
        // the tab a coin sits in, and its payment uri scheme
        #expect(catalog.tabId(asset: "xmr") == "xmr")
        for asset in ["tao", "btc", "eth", "sol"] {
            #expect(catalog.tabId(asset: asset) == SdkCryptoPaymentTabMoreCoins, "\(asset)")
        }
        #expect(catalog.tabId(asset: "card") == "")
        #expect(catalog.uriScheme(asset: "tao") == "")
        #expect(catalog.uriScheme(asset: "btc") == "bitcoin")
        #expect(catalog.uriScheme(asset: "eth") == "ethereum")
        #expect(catalog.uriScheme(asset: "sol") == "solana")
        // the asset catalog's marks, for the SDK's icon keys
        #expect(CryptoPaymentSdk.markImageName(SdkCryptoIconKeyTao) == "coin.tao")
        #expect(CryptoPaymentSdk.markImageName(SdkCryptoIconKeyBtc) == "coin.btc")
        #expect(CryptoPaymentSdk.markImageName(SdkCryptoIconKeyEth) == "coin.eth")
        #expect(CryptoPaymentSdk.markImageName(SdkCryptoIconKeySol) == "coin.sol")
        #expect(CryptoPaymentSdk.markImageName(SdkCryptoIconKeyUsdc) == nil)
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

    @Test func aTaoInvoiceHasNoPaymentLinkAndItsQrCodeIsTheAddress() {
        let address = "5FixtureBittensorColdkeyForTheAppTestsOnlyNotAWallet"
        #expect(SdkCryptoPaymentQrText("tao", "", address) == address)
        var tao = CryptoPaymentRulesTests.openXmr()
        tao.asset = "tao"
        tao.ticker = "TAO"
        tao.address = address
        tao.uri = ""
        tao.qrText = SdkCryptoPaymentQrText("tao", "", address)
        let display = CryptoInvoiceDisplay(tao, catalog: catalog)
        #expect(display.hasNoPaymentLink)
        #expect(display.qrText == address)
        #expect(display.paymentUri == nil)
        // a coin with a payment uri draws its uri, once the SDK passes it
        #expect(SdkCryptoPaymentQrText("xmr", CryptoPaymentRulesTests.xmrUri, Self.xmrAddress) == CryptoPaymentRulesTests.xmrUri)
        #expect(!CryptoInvoiceDisplay(CryptoPaymentRulesTests.openXmr(), catalog: catalog).hasNoPaymentLink)
    }

    @Test func theTickersWalletsAndMonthlyRuleAreTheSdks() {
        #expect(catalog.ticker(asset: "usdc_solana") == "USDC")
        #expect(catalog.ticker(asset: "zec") == "ZEC")
        #expect(catalog.ticker(asset: "xmr") == "XMR")
        #expect(catalog.ticker(asset: "tao") == "TAO")
        #expect(catalog.ticker(asset: "btc") == "BTC")
        #expect(catalog.ticker(asset: "eth") == "ETH")
        #expect(catalog.ticker(asset: "sol") == "SOL")
        #expect(catalog.walletSuggestions(asset: "xmr") == ["Cake", "Feather", "Monerujo", "Stack", "Unstoppable"])
        #expect(catalog.walletSuggestions(asset: "zec") == ["Zodl", "Cake", "Zingo", "Zkool", "Vizor"])
        #expect(catalog.walletSuggestions(asset: "usdc_solana") == ["Phantom", "Solflare"])
        #expect(catalog.walletSuggestions(asset: "sol") == ["Phantom", "Solflare"])
        #expect(catalog.walletSuggestions(asset: "tao") == ["btcli", "Talisman", "Nova", "SubWallet", "Polkadot.js", "Ledger", "Tangem"])
        // most wallets send Bitcoin and ETH: no line
        #expect(catalog.walletSuggestions(asset: "btc").isEmpty)
        #expect(catalog.walletSuggestions(asset: "eth").isEmpty)
        #expect(catalog.walletSuggestions(asset: "card").isEmpty)
        #expect(!catalog.allowsPlan(method: "xmr", plan: "monthly"))
        #expect(!catalog.allowsPlan(method: "tao", plan: "monthly"))
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

    @Test func theTabsComeFromTheSdkPerPlanACoinBuys() throws {
        let tabs = CryptoPaymentSdk.tabsByPlan(Self.assets([
            // the server's order means nothing; monthly is never sold
            Self.asset("xmr", plans: ["yearly", "monthly"]),
            Self.asset("usdc_solana", plans: ["yearly", "yearly_onboarding"], items: ["data_1tib"]),
            Self.asset("tao", plans: ["yearly"]),
        ]))
        let yearly = try #require(tabs["yearly"])
        // USDC on Solana, Zcash and Monero always, then More coins while one of its coins is listed
        #expect(yearly.map(\.id) == ["usdc_solana", "zec", "xmr", SdkCryptoPaymentTabMoreCoins])
        #expect(yearly.map(\.available) == [true, false, true, true])
        #expect(yearly[0].labelKey == "pay_method_usdc_solana")
        #expect(yearly[0].label == "USDC on Solana")
        let more = yearly[3]
        #expect(more.labelKey == "pay_method_more_coins")
        #expect(more.iconKeys == [SdkCryptoIconKeyTao, SdkCryptoIconKeyBtc, SdkCryptoIconKeyEth, SdkCryptoIconKeySol])
        #expect(more.coins.map(\.asset) == ["tao", "btc", "eth", "sol"])
        #expect(more.coins.map(\.available) == [true, false, false, false])
        #expect(PaymentMethodRules.methods(yearly) == [.card, .usdcSolana, .xmr, .tao])
        // the welcome offer's year: only USDC sells it, and More coins is not there
        let onboarding = try #require(tabs["yearly_onboarding"])
        #expect(onboarding.map(\.id) == ["usdc_solana", "zec", "xmr"])
        #expect(PaymentMethodRules.methods(onboarding) == [.card, .usdcSolana])
        // no assets (an older server, every coin off): no tab, Card alone, no row
        let none = CryptoPaymentSdk.tabsByPlan(nil)
        #expect(none["yearly"] == [])
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
        #expect(PaymentMethodRules.methods(viewModel.cryptoPaymentTabs(offerActive: false)) == [.card, .zec, .xmr])
        #expect(PaymentMethodRules.methods(viewModel.cryptoPaymentTabs(offerActive: true)) == [.card, .zec])
        let parsed = try #require(viewModel.cryptoTerm)
        #expect(parsed == CryptoTerm(market: "monero", termEndTime: "2027-10-20T18:00:00Z", graceEndTime: "2027-11-19T18:00:00Z"))
        #expect(parsed.graceEnd == parseRfc3339("2027-11-19T18:00:00Z"))
        #expect(viewModel.currentSubscriptionStoreClass == "crypto")

        // the next balance without them clears them
        viewModel.applyCryptoPayments(SdkSubscriptionBalanceResult())
        #expect(viewModel.cryptoPaymentTabs(offerActive: false).isEmpty)
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
        state.qrText = "solana:7xKX?amount=29.000123"
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
        expected.qrText = "solana:7xKX?amount=29.000123"
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
