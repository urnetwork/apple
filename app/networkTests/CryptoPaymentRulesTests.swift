//
//  CryptoPaymentRulesTests.swift
//  networkTests
//
//  The direct-download build's crypto payments, decided from plain values
//  (mmm/ZCASH-CONTRACT.md §6.1–§6.2): the method row's rules, and what an
//  invoice shows for each state the SDK's CryptoInvoiceViewController reports.
//  The SDK's helpers are a fake here (CryptoPaymentSdkTests runs the real
//  ones), so each decision is pinned on its own; nothing here polls or waits.
//

import CoreImage
import Foundation
import Testing
@testable import URnetwork

/// The SDK's pure helpers, scripted.
struct FakeCryptoPaymentCatalog: CryptoPaymentCatalog {
    /// The URIs CheckCryptoPaymentUri passes; any other fails.
    var passingUris: Set<String> = []
    var wallets: [String: [String]] = [
        "xmr": ["Cake", "Feather", "Monerujo", "Stack", "Unstoppable"],
        "zec": ["Zodl", "Cake", "Zingo", "Zkool", "Vizor"],
        "usdc_solana": ["Phantom", "Solflare"],
        "sol": ["Phantom", "Solflare"],
        "tao": ["btcli", "Talisman", "Nova", "SubWallet", "Polkadot.js", "Ledger", "Tangem"],
    ]

    func checkPaymentUri(asset: String, uri: String, address: String) -> Bool {
        passingUris.contains(uri)
    }

    func ticker(asset: String) -> String {
        switch asset {
        case "usdc_solana": return "USDC"
        case "zec": return "ZEC"
        case "xmr": return "XMR"
        case "tao": return "TAO"
        case "btc": return "BTC"
        case "eth": return "ETH"
        case "sol": return "SOL"
        default: return ""
        }
    }

    func walletSuggestions(asset: String) -> [String] {
        wallets[asset] ?? []
    }

    func allowsPlan(method: String, plan: String) -> Bool {
        !(method != "card" && plan == "monthly")
    }

    func uriScheme(asset: String) -> String {
        switch asset {
        case "usdc_solana", "sol": return "solana"
        case "zec": return "zcash"
        case "xmr": return "monero"
        case "btc": return "bitcoin"
        case "eth": return "ethereum"
        // TAO has no payment uri
        default: return ""
        }
    }

    func tabId(asset: String) -> String {
        switch asset {
        case "usdc_solana", "zec", "xmr": return asset
        case "tao", "btc", "eth", "sol": return "more_coins"
        default: return ""
        }
    }
}

struct CryptoPaymentRulesTests {

    static let xmrAddress = "84EwoGq9bLqKC7PZaXfSAK7v6fHEbRQ8MUP7d9oYqPz4WNsTvdJXpSnGyPkaCv7NjJK5cMMnWh1ZvKZXX3MnW5Uu3JgjgV2"
    static let xmrUri = "monero:\(xmrAddress)?tx_amount=0.072387&tx_description=URnetwork%20Pro%20yearly"

    /// An XMR invoice as the SDK shows it right after the server quoted it.
    static func openXmr(secondsLeft: Int = 1799) -> CryptoInvoiceSnapshot {
        var snapshot = CryptoInvoiceSnapshot()
        snapshot.phaseName = "open"
        snapshot.intentId = "0b6f"
        snapshot.asset = "xmr"
        snapshot.plan = "yearly"
        snapshot.address = xmrAddress
        snapshot.amount = "0.072387"
        snapshot.amountAtomic = "72387000000"
        snapshot.ticker = "XMR"
        snapshot.uri = xmrUri
        // the SDK's CryptoPaymentQrText: the uri, which passes its check
        snapshot.qrText = xmrUri
        snapshot.priceUsd = 40
        snapshot.expiresAt = "2026-10-20T18:30:00Z"
        snapshot.secondsLeft = secondsLeft
        snapshot.status = "pending"
        snapshot.confirmationsRequired = 1
        return snapshot
    }

    static let catalog = FakeCryptoPaymentCatalog(passingUris: [xmrUri])

    /// The SDK's tabs (CryptoPaymentTabs) for a balance that lists `listed`,
    /// with no unavailable list: none without a coin; else USDC on Solana,
    /// Zcash and Monero, each greyed when not listed, and More coins while one
    /// of its coins is listed (CryptoPaymentSdkTests runs the real ones).
    static func tabs(_ listed: String...) -> [CryptoPayTab] {
        guard !listed.isEmpty else {
            return []
        }
        func tab(_ id: String, _ assets: [String]) -> CryptoPayTab {
            let coins = assets.map { CryptoPayCoin(asset: $0, label: $0, labelKey: "", iconKey: "", available: listed.contains($0)) }
            return CryptoPayTab(id: id, label: id, labelKey: "", iconKeys: [], coins: coins, available: coins.contains { $0.available })
        }
        let more = ["tao", "btc", "eth", "sol"]
        var tabs = [tab("usdc_solana", ["usdc_solana"]), tab("zec", ["zec"]), tab("xmr", ["xmr"])]
        if more.contains(where: { listed.contains($0) }) {
            tabs.append(tab("more_coins", more))
        }
        return tabs
    }

    // MARK: the method row

    @Test func theRowsMethodsAreCardThenThePayableCoinsInTheTabsOrder() {
        // the SDK orders them; a greyed coin is left out, card is always first
        #expect(PaymentMethodRules.methods(Self.tabs("xmr", "usdc_solana", "zec")) == [.card, .usdcSolana, .zec, .xmr])
        #expect(PaymentMethodRules.methods(Self.tabs("xmr", "sol", "tao")) == [.card, .xmr, .tao, .sol])
        #expect(PaymentMethodRules.methods(Self.tabs("btc", "eth")) == [.card, .btc, .eth])
        #expect(PaymentMethodRules.methods(Self.tabs()) == [.card])
        // a coin this app does not know is left out
        let unknown = CryptoPayTab(
            id: "doge",
            label: "Doge",
            labelKey: "",
            iconKeys: [],
            coins: [CryptoPayCoin(asset: "doge", label: "Doge", labelKey: "", iconKey: "", available: true)],
            available: true
        )
        #expect(PaymentMethodRules.methods(Self.tabs("xmr") + [unknown]) == [.card, .xmr])
    }

    @Test func withNoCoinListedTheRowIsNotShown() {
        #expect(!PaymentMethodRules.showsRow([]))
        #expect(!PaymentMethodRules.showsRow(Self.tabs()))
        #expect(PaymentMethodRules.showsRow(Self.tabs("xmr")))
        #expect(PaymentMethodRules.showsRow(Self.tabs("tao")))
        #expect(!PaymentMethodRowState.card.isShown)
    }

    @Test func aPickOfATabChoosesItsCoin() throws {
        let tabs = Self.tabs("usdc_solana", "zec", "xmr", "btc", "sol")
        let more = try #require(tabs.first(where: { $0.id == "more_coins" }))
        // More coins picks its first coin that can be paid with: TAO is greyed here
        #expect(PaymentMethodRules.choice(more, selected: .card) == .btc)
        #expect(PaymentMethodRules.choice(more, selected: .xmr) == .btc)
        // the selected coin stays selected while it sits in the tab
        #expect(PaymentMethodRules.choice(more, selected: .sol) == .sol)
        // a greyed coin is never the pick
        #expect(PaymentMethodRules.choice(more, selected: .tao) == .btc)
        // a tab of one coin picks that coin
        #expect(PaymentMethodRules.choice(tabs[1], selected: .card) == .zec)
        // a tab none of whose coins can be paid with picks nothing
        #expect(PaymentMethodRules.choice(Self.tabs("btc")[2], selected: .card) == nil)
    }

    @Test func theRememberedMethodIsSelectedOnlyWhileTheRowListsIt() {
        let methods: [PaymentMethod] = [.card, .usdcSolana, .xmr]
        #expect(PaymentMethodRules.selected(remembered: "xmr", methods: methods) == .xmr)
        // a remembered coin the server stopped listing falls back to Card
        #expect(PaymentMethodRules.selected(remembered: "zec", methods: methods) == .card)
        // nothing remembered (the SDK's ""), or something unknown
        #expect(PaymentMethodRules.selected(remembered: "", methods: methods) == .card)
        #expect(PaymentMethodRules.selected(remembered: "doge", methods: methods) == .card)
    }

    @Test func aCoinMovesMonthlyToYearly() {
        #expect(PaymentMethodRules.plan(.monthly, allowsMonthly: false) == .yearly)
        #expect(PaymentMethodRules.plan(.yearly, allowsMonthly: false) == .yearly)
        #expect(PaymentMethodRules.plan(.monthly, allowsMonthly: true) == .monthly)
    }

    @Test func withTheWelcomeOfferACoinBuysTheOffersYear() {
        #expect(PaymentMethodRules.coinPlan(offerActive: true) == "yearly_onboarding")
        #expect(PaymentMethodRules.coinPlan(offerActive: false) == "yearly")
    }

    // the events' store is the coin's market, the SDK's CryptoAssetMarket
    // (CryptoPaymentSdkTests)
    @Test func theEventsNameAPlanTheSchemaKnows() {
        // the event schema's plans are yearly and monthly
        #expect(PaymentMethodRules.eventPlan("yearly_onboarding") == "yearly")
        #expect(PaymentMethodRules.eventPlan("yearly") == "yearly")
        #expect(PaymentMethodRules.eventPlan("monthly") == "monthly")
    }

    @Test func aMethodIsACoinByItsAsset() {
        #expect(PaymentMethod(asset: "xmr") == .xmr)
        #expect(PaymentMethod(asset: "usdc_solana") == .usdcSolana)
        #expect(PaymentMethod(asset: "tao") == .tao)
        #expect(PaymentMethod(asset: "btc") == .btc)
        #expect(PaymentMethod(asset: "eth") == .eth)
        #expect(PaymentMethod(asset: "sol") == .sol)
        #expect(PaymentMethod(asset: "card") == nil)
        #expect(PaymentMethod(asset: "") == nil)
        #expect(PaymentMethod.card.asset == nil)
        #expect(PaymentMethod.zec.asset == "zec")
    }

    // MARK: a coin's year on the plan cards

    @Test func aCoinsYearHasNoRenewalOrTrialLines() {
        // crypto-pay CONTRACT §6.1: a coin buys one year once, with no trial
        // and no renewal; Card keeps every line
        let equivalent = PlanEquivalent(monthlyEquivalent: 3.34, showEquivalent: true, savingPercent: 33)
        let offer = PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date().addingTimeInterval(86_400), appleOfferCode: "")
        let withOffer = PlanPresentation.resolve(tier: .standard, offer: offer, storeMonthly: nil, storeYearly: nil, trialDays: 14, equivalent: equivalent)
        #expect(withOffer.yearlyLines == ["then $39.99/year", "Includes 14 day free trial"])
        #expect(withOffer.yearlyLines(oneTime: true).isEmpty)
        // the price shown is what the coin pays: the offer's first year
        #expect(withOffer.yearlyTitle == "$29.99 for your first year")

        let plain = PlanPresentation.resolve(tier: .standard, offer: nil, storeMonthly: nil, storeYearly: nil, trialDays: 14, equivalent: equivalent)
        #expect(plain.yearlyLines == ["≈ $3.34/month · billed once a year", "Includes 14 day free trial"])
        #expect(plain.yearlyLines(oneTime: true) == ["≈ $3.34/month · billed once a year"])
        #expect(plain.yearlyLines(oneTime: false) == plain.yearlyLines)
    }

    // MARK: the invoice: waiting for a payment

    @Test func anOpenQuoteShowsTheNetworkTheQrTheAmountAndTheAddress() {
        let display = CryptoInvoiceDisplay(Self.openXmr(), catalog: Self.catalog)
        #expect(display.network == .monero)
        #expect(display.paymentUri == Self.xmrUri)
        #expect(display.qrText == Self.xmrUri)
        #expect(!display.hasNoPaymentLink)
        #expect(display.amount == "0.072387 XMR")
        #expect(display.amountValue == "0.072387")
        #expect(display.address == Self.xmrAddress)
        #expect(display.memo == nil)
        #expect(display.countdown == .running("29:59"))
        #expect(display.refresh == .available)
        #expect(display.steps.map(\.step) == [.waiting, .seen, .confirming(count: 0, required: 1), .paid])
        #expect(display.steps.map(\.progress) == [.current, .upcoming, .upcoming, .upcoming])
        #expect(display.wallets == ["Cake", "Feather", "Monerujo", "Stack", "Unstoppable"])
        #expect(!display.showsZcashExchangeNote)
        #expect(display.showsPayAnotherWay)
        #expect(!display.isPaid)
        #expect(!display.inReview)
    }

    @Test func aUriTheSdksCheckRefusesIsNeitherShownNorOpened() {
        // the uri pays somewhere other than the address on screen
        let display = CryptoInvoiceDisplay(Self.openXmr(), catalog: FakeCryptoPaymentCatalog())
        #expect(display.paymentUri == nil)
        #expect(display.qrText == nil)
        // the amount and the address still show, to send by hand
        #expect(display.amount == "0.072387 XMR")
        #expect(display.address == Self.xmrAddress)
    }

    @Test func noUriMeansNoQrAndTheAmountAndAddressByHand() {
        // another device requoted the invoice, or the SDK's check failed: the
        // controller blanks the uri (CONTRACT §4.4.1)
        var snapshot = Self.openXmr()
        snapshot.uri = ""
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.paymentUri == nil)
        // a QR text left over from the uri is not drawn either
        #expect(display.qrText == nil)
        #expect(display.amount == "0.072387 XMR")
        #expect(display.address == Self.xmrAddress)
        #expect(display.countdown == .running("29:59"))
    }

    @Test func theQrCodeShowsOnlyTheCheckedUriOrTheAddressOnScreen() {
        // a QR text that is neither (the SDK never hands one out) shows no code
        var elsewhere = Self.openXmr()
        elsewhere.qrText = "monero:SomewhereElse"
        #expect(CryptoInvoiceDisplay(elsewhere, catalog: Self.catalog).qrText == nil)
        var none = Self.openXmr()
        none.qrText = ""
        #expect(CryptoInvoiceDisplay(none, catalog: Self.catalog).qrText == nil)
        // no code once nothing is payable
        var seen = Self.openXmr()
        seen.status = "seen"
        seen.remaining = "0.01"
        #expect(CryptoInvoiceDisplay(seen, catalog: Self.catalog).qrText == nil)
    }

    @Test func theCountdownReadsMinutesAndSeconds() {
        #expect(CryptoInvoiceDisplay.countdownText(seconds: 1799) == "29:59")
        #expect(CryptoInvoiceDisplay.countdownText(seconds: 65) == "1:05")
        #expect(CryptoInvoiceDisplay.countdownText(seconds: 5) == "0:05")
        // a USDC quote holds an hour
        #expect(CryptoInvoiceDisplay.countdownText(seconds: 3600) == "60:00")
        #expect(CryptoInvoiceDisplay.countdownText(seconds: -3) == "0:00")
    }

    @Test func anExpiredQuoteOffersARefreshAndNothingToPay() {
        // the server says expired
        var expired = Self.openXmr(secondsLeft: 0)
        expired.status = "expired"
        // or the countdown ran out before the next poll
        let ranOut = Self.openXmr(secondsLeft: 0)
        for snapshot in [expired, ranOut] {
            let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
            #expect(display.countdown == .expired)
            #expect(display.refresh == .available)
            // a stale amount must not be paid
            #expect(display.paymentUri == nil)
            #expect(display.amount == nil)
            #expect(display.address == nil)
            #expect(display.showsPayAnotherWay)
            #expect(display.steps.first?.progress == .current)
        }
    }

    @Test func aRequoteInFlightShowsAsRefreshing() {
        var snapshot = Self.openXmr()
        snapshot.refreshing = true
        #expect(CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).refresh == .inFlight)
    }

    @Test func aFailedRequoteWithAssetUnavailableSaysTheCoinIsUnavailable() {
        var snapshot = Self.openXmr()
        snapshot.errorCode = "asset_unavailable"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.unavailable)
        #expect(display.method == .xmr)
    }

    @Test func aResumedInvoiceBeforeItsFirstPollShowsOnlyALoadingLine() {
        // the SDK gives every new or requoted invoice `pending`: no status is
        // a resumed invoice not polled yet, which may be paid already
        var snapshot = Self.openXmr()
        snapshot.status = ""
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.isAwaitingStatus)
        #expect(display.network == .monero)
        #expect(display.paymentUri == nil)
        #expect(display.amount == nil)
        #expect(display.address == nil)
        #expect(display.memo == nil)
        #expect(display.countdown == nil)
        #expect(display.steps.isEmpty)
        #expect(display.refresh == .hidden)
        // only Close until the first status
        #expect(!display.showsPayAnotherWay)
    }

    @Test func pendingWithNoTimeLeftIsExpired() {
        var snapshot = Self.openXmr(secondsLeft: 0)
        snapshot.expiresAt = ""
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.countdown == .expired)
        #expect(display.amount == nil)
        #expect(display.paymentUri == nil)
        #expect(display.refresh == .available)
    }

    @Test func onlyAPendingQuoteWithTimeLeftIsPayable() {
        // CONTRACT §6.2.1: the amount, the QR, Open in wallet, the memo and the
        // countdown show only while pending with time left
        let cases: [(status: String, secondsLeft: Int, payable: Bool)] = [
            ("pending", 1, true),
            ("pending", 0, false),
            ("expired", 0, false),
            ("seen", 900, false),
            ("confirming", 900, false),
            ("review", 900, false),
            ("", 900, false),
        ]
        for (status, secondsLeft, payable) in cases {
            var snapshot = Self.openXmr(secondsLeft: secondsLeft)
            snapshot.status = status
            let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
            #expect((display.amount != nil) == payable, "\(status) \(secondsLeft)")
            #expect((display.paymentUri != nil) == payable, "\(status) \(secondsLeft)")
            #expect((display.qrText != nil) == payable, "\(status) \(secondsLeft)")
            #expect((display.countdown.map { if case .running = $0 { return true } else { return false } } ?? false) == payable, "\(status) \(secondsLeft)")
        }
    }

    @Test func refreshAndAnotherWayOnlyWhileNothingArrived() {
        for (status, offered) in [("pending", true), ("expired", true), ("seen", false), ("confirming", false), ("paid", false), ("", false)] {
            var snapshot = Self.openXmr()
            snapshot.status = status
            let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
            #expect((display.refresh != .hidden) == offered, "\(status)")
            #expect(display.showsPayAnotherWay == offered, "\(status)")
        }
    }

    // MARK: the invoice: payments

    @Test func aPartialPaymentSaysWhatIsLeftAndHidesTheFullAmountsUri() {
        var snapshot = Self.openXmr(secondsLeft: 900)
        snapshot.status = "seen"
        snapshot.received = "0.05"
        snapshot.remaining = "0.022387"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.remaining == "0.022387 XMR")
        #expect(display.remainingValue == "0.022387")
        // the uri asks for the whole amount again: paying it would pay twice
        #expect(display.paymentUri == nil)
        #expect(display.amount == nil)
        // the rest goes to the same address, with Copy
        #expect(display.address == Self.xmrAddress)
        #expect(display.countdown == nil)
        // nothing to requote and no other way once money arrived
        #expect(display.refresh == .hidden)
        #expect(!display.showsPayAnotherWay)
        #expect(display.steps.map(\.progress) == [.done, .current, .upcoming, .upcoming])
    }

    @Test func aSeenPaymentWithNothingLeftSaysNothingMore() {
        var snapshot = Self.openXmr()
        snapshot.status = "seen"
        snapshot.remaining = "0"
        #expect(CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).remaining == nil)
    }

    @Test func confirmingShowsTheCountAndNothingToPay() {
        var snapshot = Self.openXmr()
        snapshot.status = "confirming"
        snapshot.confirmations = 3
        snapshot.confirmationsRequired = 10
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.steps.map(\.step) == [.waiting, .seen, .confirming(count: 3, required: 10), .paid])
        #expect(display.steps.map(\.progress) == [.done, .done, .current, .upcoming])
        #expect(display.currentStep == .confirming(count: 3, required: 10))
        #expect(display.paymentUri == nil)
        #expect(display.amount == nil)
        #expect(display.address == nil)
        #expect(display.countdown == nil)
        #expect(display.refresh == .hidden)
        #expect(!display.showsPayAnotherWay)
        #expect(display.wallets.isEmpty)
    }

    @Test func paidMarksEveryStepDone() {
        var snapshot = Self.openXmr()
        snapshot.phaseName = "paid"
        snapshot.status = "paid"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.isPaid)
        #expect(display.steps.allSatisfy { $0.progress == .done })
        #expect(display.currentStep == .paid)
        #expect(display.paymentUri == nil)
        #expect(!display.showsPayAnotherWay)
    }

    @Test func reviewShowsTheReviewCopyAndNothingElseToDo() {
        var snapshot = Self.openXmr()
        snapshot.status = "review"
        snapshot.reviewReason = "underpaid"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.inReview)
        #expect(display.network == .monero)
        #expect(display.paymentUri == nil)
        #expect(display.amount == nil)
        #expect(display.address == nil)
        #expect(display.countdown == nil)
        #expect(display.steps.isEmpty)
        #expect(display.wallets.isEmpty)
        #expect(!display.showsPayAnotherWay)
    }

    @Test func anInvoiceTheServerNoLongerKnowsOffersAnotherWay() {
        var snapshot = Self.openXmr()
        snapshot.phaseName = "failed"
        snapshot.status = "unknown"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.isFailed)
        #expect(display.showsPayAnotherWay)
        #expect(display.paymentUri == nil)
    }

    @Test func aFailedInvoiceOffersAnotherWay() {
        var snapshot = CryptoInvoiceSnapshot()
        snapshot.phaseName = "failed"
        snapshot.asset = "zec"
        snapshot.errorCode = "start_failed"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.isFailed)
        #expect(display.showsPayAnotherWay)
        #expect(!display.isAwaitingStatus)
    }

    @Test func startingShowsOnlyTheNetwork() {
        var snapshot = CryptoInvoiceSnapshot()
        snapshot.phaseName = "starting"
        snapshot.asset = "zec"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.isStarting)
        #expect(display.network == .zcashShielded)
        #expect(display.steps.isEmpty)
        #expect(!display.showsPayAnotherWay)
    }

    // MARK: the invoice: per coin

    @Test func usdcShowsItsMemoTheAddressForItsNetworkWarningAndStepsWaitingToPaid() {
        let address = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
        let uri = "solana:\(address)?amount=40.000123&spl-token=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v&reference=8X&label=URnetwork&message=URnetwork%20Pro%20yearly"
        var snapshot = Self.openXmr(secondsLeft: 3600)
        snapshot.asset = "usdc_solana"
        snapshot.ticker = "USDC"
        snapshot.address = address
        snapshot.amount = "40.000123"
        snapshot.uri = uri
        snapshot.qrText = uri
        snapshot.memo = "8XrefMemo"
        let display = CryptoInvoiceDisplay(snapshot, catalog: FakeCryptoPaymentCatalog(passingUris: [uri]))
        #expect(display.network == .usdcOnSolana)
        #expect(display.method == .usdcSolana)
        #expect(display.amount == "40.000123 USDC")
        #expect(display.memo == "8XrefMemo")
        // the network-only warning shows with the address (PaymentMethod.networkWarning)
        #expect(display.address == address)
        #expect(display.qrText == uri)
        #expect(display.countdown == .running("60:00"))
        // USDC reports only pending, paid and expired
        #expect(display.steps.map(\.step) == [.waiting, .paid])
        #expect(display.wallets == ["Phantom", "Solflare"])
        #expect(!display.showsZcashExchangeNote)
    }

    @Test func aMemoOnAnotherCoinIsIgnored() {
        var snapshot = Self.openXmr()
        snapshot.memo = "stray"
        #expect(CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).memo == nil)
    }

    @Test func aSolInvoiceCarriesItsMemoAsUsdcDoes() {
        let address = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
        let uri = "solana:\(address)?amount=0.204517&reference=8X&label=URnetwork"
        var snapshot = Self.openXmr(secondsLeft: 1800)
        snapshot.asset = "sol"
        snapshot.ticker = "SOL"
        snapshot.address = address
        snapshot.amount = "0.204517"
        snapshot.uri = uri
        snapshot.qrText = uri
        snapshot.memo = "8XrefMemo"
        let display = CryptoInvoiceDisplay(snapshot, catalog: FakeCryptoPaymentCatalog(passingUris: [uri]))
        #expect(display.network == .solana)
        #expect(display.memo == "8XrefMemo")
        #expect(display.paymentUri == uri)
        #expect(display.qrText == uri)
        #expect(!display.hasNoPaymentLink)
        #expect(display.amount == "0.204517 SOL")
    }

    // TAO has no payment uri (mmm/BTCPAY.md §17.6): a QR code of the address
    // alone, no Open in wallet, and the amount and the address sent by hand
    @Test func aTaoInvoiceShowsTheAddressAsItsQrCodeAndNoOpenInWallet() {
        let address = "5FixtureBittensorColdkeyForTheAppTestsOnlyNotAWallet"
        var snapshot = Self.openXmr()
        snapshot.asset = "tao"
        snapshot.ticker = "TAO"
        snapshot.address = address
        snapshot.amount = "0.123457"
        snapshot.uri = ""
        // the SDK's CryptoPaymentQrText for a coin without a payment uri
        snapshot.qrText = address
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.method == .tao)
        #expect(display.network == .bittensor)
        #expect(display.hasNoPaymentLink)
        #expect(display.paymentUri == nil)
        #expect(display.qrText == address)
        #expect(display.amount == "0.123457 TAO")
        #expect(display.amountValue == "0.123457")
        #expect(display.address == address)
        #expect(display.memo == nil)
        #expect(display.countdown == .running("29:59"))
        #expect(display.wallets == ["btcli", "Talisman", "Nova", "SubWallet", "Polkadot.js", "Ledger", "Tangem"])
        #expect(display.steps.map(\.step) == [.waiting, .seen, .confirming(count: 0, required: 1), .paid])

        // the quote ran out: no amount, and no code of the address either
        var expired = snapshot
        expired.status = "expired"
        expired.secondsLeft = 0
        let expiredDisplay = CryptoInvoiceDisplay(expired, catalog: Self.catalog)
        #expect(expiredDisplay.qrText == nil)
        #expect(expiredDisplay.amount == nil)
        // part of it arrived: the address stays for the rest
        var seen = snapshot
        seen.status = "seen"
        seen.remaining = "0.023457"
        let seenDisplay = CryptoInvoiceDisplay(seen, catalog: Self.catalog)
        #expect(seenDisplay.qrText == nil)
        #expect(seenDisplay.address == address)
        #expect(seenDisplay.remaining == "0.023457 TAO")
    }

    @Test func theNewCoinsNameTheirNetworks() {
        #expect(CryptoInvoiceDisplay.networkLine(for: .tao) == .bittensor)
        #expect(CryptoInvoiceDisplay.networkLine(for: .btc) == .bitcoin)
        #expect(CryptoInvoiceDisplay.networkLine(for: .eth) == .ethereum)
        #expect(CryptoInvoiceDisplay.networkLine(for: .sol) == .solana)
        #expect(CryptoInvoiceDisplay.networkLine(for: .card) == nil)
        // Bitcoin and ETH have payment uris
        for asset in ["btc", "eth"] {
            var snapshot = Self.openXmr()
            snapshot.asset = asset
            #expect(!CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).hasNoPaymentLink, "\(asset)")
        }
    }

    @Test func zcashNamesTheShieldedNetworkAndWarnsAboutExchanges() {
        var snapshot = Self.openXmr()
        snapshot.asset = "zec"
        snapshot.ticker = "ZEC"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.network == .zcashShielded)
        #expect(display.showsZcashExchangeNote)
        #expect(display.wallets == ["Zodl", "Cake", "Zingo", "Zkool", "Vizor"])
        #expect(display.amount == "0.072387 ZEC")
    }

    @Test func aMissingTickerComesFromTheSdk() {
        var snapshot = Self.openXmr()
        snapshot.ticker = ""
        #expect(CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).amount == "0.072387 XMR")
    }

    // MARK: the snapshot

    @Test func anUnknownPhaseReadsAsNone() {
        var snapshot = CryptoInvoiceSnapshot()
        snapshot.phaseName = "somethingNew"
        #expect(snapshot.phase == .none)
        #expect(!snapshot.isInProgress)
    }

    @Test func inProgressIsStartingOrOpenAndNotPaid() {
        var snapshot = Self.openXmr()
        #expect(snapshot.isInProgress)
        snapshot.phaseName = "starting"
        #expect(snapshot.isInProgress)
        snapshot.phaseName = "open"
        snapshot.status = "paid"
        #expect(!snapshot.isInProgress)
        snapshot.phaseName = "failed"
        snapshot.status = ""
        #expect(!snapshot.isInProgress)
        snapshot.phaseName = "none"
        #expect(!snapshot.isInProgress)
    }

    // MARK: the paid year's end

    @Test func theTermShowsWhenItsGraceEnds() {
        // whether the notice shows is the SDK's rule (CryptoPaymentSdkTests)
        let term = CryptoTerm(market: "monero", termEndTime: "2027-10-20T18:00:00Z", graceEndTime: "2027-11-19T18:00:00Z")
        #expect(term.graceEnd == parseRfc3339("2027-11-19T18:00:00Z"))
        #expect(CryptoTerm(market: "zcash", termEndTime: "2027-10-20T18:00:00Z", graceEndTime: "nope").graceEnd == nil)
    }

    @Test func serverTimesParseWithOrWithoutFractionsAndOffsets() throws {
        let plain = try #require(parseRfc3339("2026-10-20T18:00:00Z"))
        #expect(plain == Date(timeIntervalSince1970: 1_792_519_200))
        // Go writes nanoseconds
        let nanos = try #require(parseRfc3339("2026-10-20T18:00:00.123456789Z"))
        #expect(abs(nanos.timeIntervalSince(plain) - 0.123) < 0.0005)
        let offset = try #require(parseRfc3339("2026-10-20T20:00:00+02:00"))
        #expect(offset == plain)
        #expect(parseRfc3339("") == nil)
        #expect(parseRfc3339("yesterday") == nil)
    }

    @Test func aCryptoYearHasNothingToManageInTheStripePortal() {
        // the direct-download build: a one-time year never renews
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true, storeClass: "crypto") == nil)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true, storeClass: "stripe") == .stripePortal)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true) == .stripePortal)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: false, storeClass: "crypto") == nil)
        // the App Store builds are as they were, whatever the store
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true, storeClass: "crypto") == .manageOnWeb)
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true, storeClass: "crypto") == .storeKitSheet)
    }

    @Test func onlyTheCryptoStoreFamilyIsCrypto() {
        #expect(subscriptionStoreIsCrypto("crypto"))
        #expect(!subscriptionStoreIsCrypto("stripe"))
        #expect(!subscriptionStoreIsCrypto("other"))
        #expect(!subscriptionStoreIsCrypto(""))
    }

    // MARK: the QR code

    @Test func theQrCodeCarriesExactlyTheServersUri() throws {
        let image = try #require(cryptoPaymentQrImage(Self.xmrUri))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        // one pixel per module is too small to read: scale it up as the view does
        let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let quietZone = CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -40, dy: -40))
        let features = detector.features(in: scaled.composited(over: quietZone))
        let decoded = features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(decoded == [Self.xmrUri])
        #expect(cryptoPaymentQrImage("") == nil)
    }
}
