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
    /// CryptoWalletSuggestions: TAO's alone (the owner, 2026-11-11); every
    /// other coin names none.
    var wallets: [String: [String]] = [
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

    // the SDK's CryptoPaymentTabCoin, as its vectors pin it
    func tabCoin(_ tab: CryptoPayTab, lastChosen: String, remembered: String) -> String {
        let choosable = tab.coins.filter { $0.available && !ticker(asset: $0.asset).isEmpty }.map(\.asset)
        if choosable.contains(lastChosen) {
            return lastChosen
        }
        if choosable.contains(remembered) {
            return remembered
        }
        return choosable.first ?? ""
    }

    func lines(asset: String) -> CryptoAssetLines {
        func line(_ key: String) -> CryptoPayLine? {
            CryptoPayLine(key: key, english: key)
        }
        switch asset {
        case "usdc_solana":
            return CryptoAssetLines(networkLine: line("crypto_network_usdc"), networkWarning: line("usdc_solana_network_only"), noPaymentLinkNote: nil)
        case "zec":
            return CryptoAssetLines(networkLine: line("crypto_network_zcash"), networkWarning: nil, noPaymentLinkNote: nil)
        case "xmr":
            return CryptoAssetLines(networkLine: line("crypto_network_monero"), networkWarning: nil, noPaymentLinkNote: nil)
        case "tao":
            return CryptoAssetLines(networkLine: line("crypto_network_tao"), networkWarning: line("crypto_invoice_tao_network_only"), noPaymentLinkNote: line("crypto_invoice_tao_no_payment_link"))
        case "btc":
            return CryptoAssetLines(networkLine: line("crypto_network_bitcoin"), networkWarning: line("crypto_invoice_bitcoin_network_only"), noPaymentLinkNote: nil)
        case "eth":
            return CryptoAssetLines(networkLine: line("crypto_network_eth"), networkWarning: line("crypto_invoice_eth_network_only"), noPaymentLinkNote: nil)
        case "sol":
            return CryptoAssetLines(networkLine: line("crypto_network_sol"), networkWarning: line("crypto_invoice_sol_network_only"), noPaymentLinkNote: nil)
        default:
            return .none
        }
    }

    // the SDK's CryptoPaymentShowsMemo: a memo the server sent, for a coin it knows
    func showsMemo(asset: String, memo: String) -> Bool {
        !ticker(asset: asset).isEmpty && !memo.isEmpty
    }

    // the SDK's CryptoPaymentSteps, as its vectors pin it
    func steps(asset: String, status: String, confirmations: Int, confirmationsRequired: Int) -> [CryptoPaymentStepValue] {
        guard !ticker(asset: asset).isEmpty else {
            return []
        }
        var statuses = ["pending", "paid"]
        if asset != "usdc_solana" {
            statuses = ["pending", "seen"] + (0 < confirmationsRequired ? ["confirming"] : []) + ["paid"]
        }
        let current: Int
        switch status {
        case "pending", "expired":
            current = 0
        case "seen", "confirming", "paid":
            current = statuses.firstIndex(of: status) ?? statuses.count - 2
        default:
            return []
        }
        return statuses.enumerated().map { index, stepStatus in
            let progress = status == "paid" || index < current ? "done" : index == current ? "current" : "upcoming"
            guard stepStatus == "confirming" else {
                return CryptoPaymentStepValue(status: stepStatus, progress: progress)
            }
            let count = progress == "done" ? confirmationsRequired : progress == "current" ? min(max(confirmations, 0), confirmationsRequired) : 0
            return CryptoPaymentStepValue(status: stepStatus, progress: progress, confirmations: count, confirmationsRequired: confirmationsRequired)
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
        // the SDK's line for the coin, by its key; Monero has no network warning
        #expect(display.networkLine?.key == "crypto_network_monero")
        #expect(display.networkWarning == nil)
        #expect(display.noPaymentLinkNote == nil)
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
        // Monero names no wallets (the SDK names TAO's alone): no such line
        #expect(display.wallets.isEmpty)
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
        #expect(display.networkLine?.key == "crypto_network_monero")
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
        #expect(display.networkLine?.key == "crypto_network_monero")
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
        #expect(display.networkLine?.key == "crypto_network_zcash")
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
        #expect(display.networkLine?.key == "crypto_network_usdc")
        #expect(display.method == .usdcSolana)
        #expect(display.amount == "40.000123 USDC")
        #expect(display.memo == "8XrefMemo")
        // the network-only warning shows with the address (the SDK's line)
        #expect(display.networkWarning?.key == "usdc_solana_network_only")
        #expect(display.address == address)
        #expect(display.qrText == uri)
        #expect(display.countdown == .running("60:00"))
        // USDC reports only pending, paid and expired
        #expect(display.steps.map(\.step) == [.waiting, .paid])
        // USDC names no wallets either: no such line
        #expect(display.wallets.isEmpty)
        #expect(!display.showsZcashExchangeNote)
    }

    /// The SDK's rule only, never the coin: a catalog that says no hides even
    /// USDC's memo, and no memo, no row.
    struct NoMemoCatalog: CryptoPaymentCatalog {
        var base = FakeCryptoPaymentCatalog(passingUris: [CryptoPaymentRulesTests.xmrUri])
        func checkPaymentUri(asset: String, uri: String, address: String) -> Bool { base.checkPaymentUri(asset: asset, uri: uri, address: address) }
        func ticker(asset: String) -> String { base.ticker(asset: asset) }
        func walletSuggestions(asset: String) -> [String] { base.walletSuggestions(asset: asset) }
        func allowsPlan(method: String, plan: String) -> Bool { base.allowsPlan(method: method, plan: plan) }
        func uriScheme(asset: String) -> String { base.uriScheme(asset: asset) }
        func tabId(asset: String) -> String { base.tabId(asset: asset) }
        func tabCoin(_ tab: CryptoPayTab, lastChosen: String, remembered: String) -> String {
            base.tabCoin(tab, lastChosen: lastChosen, remembered: remembered)
        }
        func lines(asset: String) -> CryptoAssetLines { base.lines(asset: asset) }
        func showsMemo(asset: String, memo: String) -> Bool { false }
        func steps(asset: String, status: String, confirmations: Int, confirmationsRequired: Int) -> [CryptoPaymentStepValue] {
            base.steps(asset: asset, status: status, confirmations: confirmations, confirmationsRequired: confirmationsRequired)
        }
    }

    @Test func theMemoShowsWhenTheSdkSaysSo() {
        var snapshot = Self.openXmr()
        snapshot.asset = "usdc_solana"
        snapshot.memo = "8XrefMemo"
        #expect(CryptoInvoiceDisplay(snapshot, catalog: NoMemoCatalog()).memo == nil)
        var none = Self.openXmr()
        none.memo = ""
        #expect(CryptoInvoiceDisplay(none, catalog: Self.catalog).memo == nil)
    }

    // the server sends "memo": "" for SOL (its own deposit address names the
    // invoice), and the SDK shows a memo only when there is one: the invoice
    // used to show a memo row for SOL as for USDC
    @Test func aSolInvoiceShowsNoMemo() {
        let address = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
        let uri = "solana:\(address)?amount=0.204517&reference=8X&label=URnetwork"
        var snapshot = Self.openXmr(secondsLeft: 1800)
        snapshot.asset = "sol"
        snapshot.ticker = "SOL"
        snapshot.address = address
        snapshot.amount = "0.204517"
        snapshot.uri = uri
        snapshot.qrText = uri
        snapshot.memo = ""
        let display = CryptoInvoiceDisplay(snapshot, catalog: FakeCryptoPaymentCatalog(passingUris: [uri]))
        #expect(display.networkLine?.key == "crypto_network_sol")
        #expect(display.networkWarning?.key == "crypto_invoice_sol_network_only")
        #expect(display.memo == nil)
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
        #expect(display.networkLine?.key == "crypto_network_tao")
        #expect(display.networkWarning?.key == "crypto_invoice_tao_network_only")
        #expect(display.noPaymentLinkNote?.key == "crypto_invoice_tao_no_payment_link")
        #expect(display.hasNoPaymentLink)
        #expect(display.paymentUri == nil)
        #expect(display.qrText == address)
        #expect(display.amount == "0.123457 TAO")
        #expect(display.amountValue == "0.123457")
        #expect(display.address == address)
        #expect(display.memo == nil)
        #expect(display.countdown == .running("29:59"))
        // the one coin the SDK names wallets for
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
        // confirming or in review: nothing more to send, so no wallets either
        for status in ["confirming", "review"] {
            var settled = snapshot
            settled.status = status
            #expect(CryptoInvoiceDisplay(settled, catalog: Self.catalog).wallets.isEmpty, "\(status)")
        }
    }

    @Test func theNewCoinsNameTheirNetworksWithTheSdksLines() {
        for (asset, key) in [("tao", "crypto_network_tao"), ("btc", "crypto_network_bitcoin"), ("eth", "crypto_network_eth"), ("sol", "crypto_network_sol")] {
            var snapshot = Self.openXmr()
            snapshot.asset = asset
            #expect(CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).networkLine?.key == key, "\(asset)")
        }
        // not a coin: no line at all, and the invoice is titled Get Pro
        var card = Self.openXmr()
        card.asset = "card"
        #expect(CryptoInvoiceDisplay(card, catalog: Self.catalog).networkLine == nil)
        // an empty key is no line
        #expect(CryptoPayLine(key: "", english: "anything") == nil)
        // Bitcoin and ETH have payment uris
        for asset in ["btc", "eth"] {
            var snapshot = Self.openXmr()
            snapshot.asset = asset
            #expect(!CryptoInvoiceDisplay(snapshot, catalog: Self.catalog).hasNoPaymentLink, "\(asset)")
        }
    }

    // SOL and TAO, which the server sees only once final, usually go from
    // pending straight to paid: every step they skipped is drawn done, as the
    // SDK draws it
    @Test func aPaymentThatSkippedStepsShowsThemDone() {
        var snapshot = Self.openXmr()
        snapshot.asset = "sol"
        snapshot.phaseName = "paid"
        snapshot.status = "paid"
        snapshot.confirmations = 0
        snapshot.confirmationsRequired = 1
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.steps.map(\.step) == [.waiting, .seen, .confirming(count: 1, required: 1), .paid])
        #expect(display.steps.allSatisfy { $0.progress == .done })
    }

    @Test func theSdksStepsBecomeRows() {
        let rows = CryptoInvoiceDisplay.stepRows([
            CryptoPaymentStepValue(status: "pending", progress: "done"),
            CryptoPaymentStepValue(status: "seen", progress: "current"),
            CryptoPaymentStepValue(status: "confirming", progress: "upcoming", confirmations: 0, confirmationsRequired: 10),
            CryptoPaymentStepValue(status: "paid", progress: "upcoming"),
            // a step this app does not know is left out
            CryptoPaymentStepValue(status: "refunded", progress: "upcoming"),
        ])
        #expect(rows.map(\.step) == [.waiting, .seen, .confirming(count: 0, required: 10), .paid])
        #expect(rows.map(\.progress) == [.done, .current, .upcoming, .upcoming])
    }

    @Test func zcashNamesTheShieldedNetworkAndWarnsAboutExchanges() {
        var snapshot = Self.openXmr()
        snapshot.asset = "zec"
        snapshot.ticker = "ZEC"
        let display = CryptoInvoiceDisplay(snapshot, catalog: Self.catalog)
        #expect(display.networkLine?.key == "crypto_network_zcash")
        #expect(display.networkWarning == nil)
        #expect(display.showsZcashExchangeNote)
        // Zcash names no wallets (the SDK names TAO's alone): no such line
        #expect(display.wallets.isEmpty)
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
