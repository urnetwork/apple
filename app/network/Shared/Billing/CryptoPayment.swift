//
//  CryptoPayment.swift
//  URnetwork
//
//  The direct-download build's crypto payments (mmm/ZCASH-CONTRACT.md §4.3–§6,
//  mmm ZCASH.md §0.1/§0.3, the coin tabs of mmm/BTCPAY.md §17.6): the method
//  row's rules and what an invoice shows, decided from plain values so they
//  are unit tested.
//
//  Pure: no SwiftUI and no strings, so it compiles in both builds (the unit
//  test host is the App Store app). The views and every crypto string compile
//  only under DIRECT_DOWNLOAD (Shared/Views/CryptoPay). The SDK owns the coin
//  tabs (their order, labels, marks and availability), the tab a method sits
//  in and the coin a tap on a tab chooses, each coin's lines (network line,
//  network-only warning, no-payment-link note), the URI check and the QR
//  code's text, when the memo shows, the status steps, the tickers, markets,
//  event products and URI schemes, the wallet names and the invoice state
//  machine (CryptoPaymentSdk.swift); nothing here re-derives them.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// MARK: - methods

/// A way to pay on the method row (CONTRACT §1 "method"): Card (Stripe), or a
/// coin, named by the asset it pays in. The raw values are the SDK's
/// (PaymentMethodCard, CryptoAsset*). The row's order is the SDK's tabs'
/// (CryptoPaymentTabs), never this list's.
enum PaymentMethod: String, Hashable {
    case card
    case usdcSolana = "usdc_solana"
    case zec
    case xmr
    /// TAO, on Bittensor
    case tao
    case btc
    case eth
    /// native SOL
    case sol

    var isCoin: Bool {
        self != .card
    }

    /// The asset a coin pays in; nil for Card.
    var asset: String? {
        isCoin ? rawValue : nil
    }

    /// The coin that pays in `asset`; nil for an asset this app does not know.
    init?(asset: String) {
        guard let method = PaymentMethod(rawValue: asset), method.isCoin else {
            return nil
        }
        self = method
    }
}

/// A coin of the payment widget, the SDK's CryptoPaymentCoin as plain values.
/// An unavailable coin stays in its place and cannot be chosen: its label is
/// greyed, with "Temporarily unavailable" beside it, and its mark is never
/// dimmed (Solana's and Bittensor's marks are shown only at full contrast).
struct CryptoPayCoin: Equatable, Hashable {
    /// One of the SDK's CryptoAsset* values.
    var asset: String
    /// In English (the SDK's Label), shown when the app has no string for `labelKey`.
    var label: String
    /// The label's string id in the shared localizations.
    var labelKey: String
    /// The coin's mark, one of the SDK's CryptoIconKey* values.
    var iconKey: String
    /// Payable now, for one of the surface's items.
    var available: Bool
}

/// A tab of the coin selector, the SDK's CryptoPaymentTab as plain values: a
/// tab of one coin (its id is the coin's asset), or "More coins"
/// (CryptoPaymentTabMoreCoins), which shows its coins' marks as separate marks
/// with space between them and opens a list of its coins.
struct CryptoPayTab: Equatable, Hashable {
    var id: String
    /// In English (the SDK's Label), shown when the app has no string for `labelKey`.
    var label: String
    var labelKey: String
    /// The marks the tab shows, in order, each at full contrast.
    var iconKeys: [String]
    /// Its coins, in order: one, or TAO, Bitcoin, ETH and SOL.
    var coins: [CryptoPayCoin]
    /// One of its coins can be paid with now; a tab with none is greyed and cannot be chosen.
    var available: Bool
}

/// The method row's rules (CONTRACT §6.1).
enum PaymentMethodRules {

    /// The plans the server sells for a coin (CONTRACT §1 "item").
    static let planYearly = "yearly"
    static let planYearlyOnboarding = "yearly_onboarding"
    static let planMonthly = "monthly"

    /// The methods that can be chosen on a row with `tabs` (the SDK's
    /// CryptoPaymentTabs for the item the coin would buy): Card first, then
    /// each coin that can be paid with now, in the tabs' order. A coin this
    /// app does not know is left out.
    static func methods(_ tabs: [CryptoPayTab]) -> [PaymentMethod] {
        let coins: [PaymentMethod] = tabs.flatMap { $0.coins }.filter { $0.available }.compactMap { PaymentMethod(asset: $0.asset) }
        return [PaymentMethod.card] + coins
    }

    /// The row shows only when the server lists a coin (the SDK lists no tab
    /// otherwise); with Card alone the surface looks exactly as it did before
    /// crypto.
    static func showsRow(_ tabs: [CryptoPayTab]) -> Bool {
        !tabs.isEmpty
    }

    /// The selected method: the one remembered on this device while it can be
    /// chosen, else Card (a remembered coin the server stopped listing, or one
    /// that is greyed out, falls back to Card).
    static func selected(remembered: String, methods: [PaymentMethod]) -> PaymentMethod {
        guard let method = PaymentMethod(rawValue: remembered), methods.contains(method) else {
            return .card
        }
        return method
    }

    /// The plan a coin buys on a plan surface: the welcome offer while one is
    /// active (the card path keeps its own trial and coupon), else yearly.
    /// No coin sells monthly (decision 6).
    static func coinPlan(offerActive: Bool) -> String {
        offerActive ? planYearlyOnboarding : planYearly
    }

    /// The plan name of a plan card, as the SDK's PaymentMethodAllowsPlan takes it.
    static func planName(_ plan: PaymentOption) -> String {
        plan == .monthly ? planMonthly : planYearly
    }

    /// The plan the offer and purchase events carry: the event schema knows
    /// yearly and monthly, so the welcome offer's year is yearly.
    static func eventPlan(_ plan: String) -> String {
        plan == planYearlyOnboarding ? planYearly : plan
    }

    /// The plan selection once `method` is picked: a coin moves monthly to
    /// yearly (`allowsMonthly` is the SDK's PaymentMethodAllowsPlan for monthly).
    static func plan(_ plan: PaymentOption, allowsMonthly: Bool) -> PaymentOption {
        plan == .monthly && !allowsMonthly ? .yearly : plan
    }
}

/// One surface's method row as its views render it.
struct PaymentMethodRowState: Equatable {
    /// The SDK's coin tabs after Card: USDC on Solana, Zcash, Monero and More
    /// coins; none when no coin is listed.
    var tabs: [CryptoPayTab]
    /// Card first, then the coins that can be chosen now.
    var methods: [PaymentMethod]
    var selected: PaymentMethod
    /// The tab the selected method sits in (the SDK's CryptoPaymentTabId): ""
    /// for Card.
    var selectedTabId: String
    /// What a tap on each tab chooses, by tab id (the SDK's
    /// CryptoPaymentTabCoin: the coin last chosen in the tab, else the
    /// remembered method's, else its first that can be paid with); a tab none
    /// of whose coins can be paid with has none, and cannot be chosen.
    var tabChoices: [String: PaymentMethod]
    /// The selected coin's last start failed with asset_unavailable: the row
    /// says "Temporarily unavailable" under it and the coin stays selectable.
    var selectedUnavailable: Bool
    /// The monthly plan can be bought with the selected method.
    var allowsMonthly: Bool

    var isShown: Bool {
        PaymentMethodRules.showsRow(tabs)
    }

    /// Card, as every surface was before crypto.
    static let card = PaymentMethodRowState(
        tabs: [],
        methods: [.card],
        selected: .card,
        selectedTabId: "",
        tabChoices: [:],
        selectedUnavailable: false,
        allowsMonthly: true
    )
}

// MARK: - purchase errors

/// The server's purchase refusals the crypto start has its own handling for
/// (CONTRACT §2.7, PurchaseErrorCode*).
enum CryptoPurchaseErrorCode {
    static let assetUnavailable = "asset_unavailable"
    static let quoteExpired = "quote_expired"
    static let underpaid = "underpaid"
    static let guestSignInRequired = "guest_sign_in_required"
}

/// A start the server refused for a reason the surface words with its
/// existing refusal handling (CheckoutRefusal): rate limited, offer
/// unavailable, start failed and the rest. asset_unavailable and the guest
/// refusal never get here (the row and the add-sign-in sheet handle those).
struct CryptoPurchaseRefusal: Equatable {
    var code: String
    var message: String
}

// MARK: - invoice state

/// The SDK's CryptoInvoiceState (CONTRACT §4.4) as plain values.
struct CryptoInvoiceSnapshot: Equatable {

    enum Phase: String {
        case none
        case starting
        case open
        case paid
        case failed
    }

    /// The SDK's phase string: none | starting | open | paid | failed.
    var phaseName: String = Phase.none.rawValue
    var intentId: String = ""
    var asset: String = ""
    var plan: String = ""
    var itemId: String = ""
    var delivery: String = ""
    var networkName: String = ""
    var address: String = ""
    /// Exact decimal strings (never floats): "0.072387".
    var amount: String = ""
    var amountAtomic: String = ""
    var ticker: String = ""
    var uri: String = ""
    /// What the QR code encodes (the SDK's CryptoPaymentQrText): `uri`, or for
    /// TAO the address alone; "" for no QR code.
    var qrText: String = ""
    var memo: String = ""
    var priceUsd: Double = 0
    var rateUsd: Double = 0
    /// RFC 3339.
    var expiresAt: String = ""
    /// 0 once expired.
    var secondsLeft: Int = 0
    /// CONTRACT §2.5: pending | seen | confirming | paid | expired | review | unknown.
    var status: String = ""
    var reviewReason: String = ""
    var received: String = ""
    var remaining: String = ""
    var confirmations: Int = 0
    var confirmationsRequired: Int = 0
    var balanceCode: String = ""
    /// A requote is in flight.
    var refreshing: Bool = false
    /// The last start or requote failure, e.g. asset_unavailable.
    var errorCode: String = ""
    var errorMessage: String = ""

    /// An unknown phase string reads as none (nothing to show).
    var phase: Phase {
        Phase(rawValue: phaseName) ?? .none
    }

    var isPaid: Bool {
        phase == .paid || status == CryptoPaymentStatus.paid
    }

    /// An invoice is open (or starting) and not paid: the account screen
    /// offers it again, and the upgrade surfaces show it over their plans.
    var isInProgress: Bool {
        (phase == .starting || phase == .open) && !isPaid
    }

    /// The server says nothing arrived: pending, or expired with nothing
    /// received. Only then is a requote allowed, and "Pay another way" drops
    /// the invoice (a resumed invoice before its first poll may be paid).
    var isAwaitingPayment: Bool {
        status == CryptoPaymentStatus.pending || status == CryptoPaymentStatus.expired
    }
}

/// The status values of CONTRACT §2.5 (the SDK's CryptoPaymentStatus*).
enum CryptoPaymentStatus {
    static let pending = "pending"
    static let seen = "seen"
    static let confirming = "confirming"
    static let paid = "paid"
    static let expired = "expired"
    static let review = "review"
    static let unknown = "unknown"
}

/// How the SDK draws one of an invoice's status steps (its
/// CryptoPaymentStepDone, CryptoPaymentStepCurrent, CryptoPaymentStepUpcoming).
enum CryptoPaymentStepProgress {
    static let done = "done"
    static let current = "current"
    static let upcoming = "upcoming"
}

// MARK: - what the invoice shows

/// One of a coin's lines on its invoice (the SDK's CryptoAssetLinesFor): its
/// string id in the shared localizations, which the views look the line up by,
/// and the SDK's English, shown for an id this app has no string for.
struct CryptoPayLine: Equatable {
    var key: String
    var english: String

    /// A line the coin has; nil for an empty id, a line it does not have.
    init?(key: String, english: String) {
        guard !key.isEmpty else {
            return nil
        }
        self.key = key
        self.english = english
    }
}

/// A coin's lines (the SDK's CryptoAssetLinesFor), each nil for a line the
/// coin does not have: the network it is sent on (the invoice's first line,
/// and the line under the coin in the More coins list), the network-only
/// warning shown with the address (none for Zcash and Monero), and the note
/// under the QR code of a coin without a payment link (TAO's).
struct CryptoAssetLines: Equatable {
    var networkLine: CryptoPayLine?
    var networkWarning: CryptoPayLine?
    var noPaymentLinkNote: CryptoPayLine?

    static let none = CryptoAssetLines(networkLine: nil, networkWarning: nil, noPaymentLinkNote: nil)
}

/// One of an invoice's status steps as the SDK draws it (CryptoPaymentSteps).
struct CryptoPaymentStepValue: Equatable {
    /// The status the step stands for: pending, seen, confirming or paid.
    var status: String
    /// done, current or upcoming (the SDK's CryptoPaymentStep*): a step the
    /// payment skipped is done, and once paid every step is.
    var progress: String
    /// The confirming step's "Confirming: n of N"; 0 for the others.
    var confirmations: Int = 0
    var confirmationsRequired: Int = 0
}

/// The SDK's pure helpers an invoice is drawn with (CONTRACT §4.3), behind a
/// protocol so the display decisions are tested without the SDK.
protocol CryptoPaymentCatalog {
    /// CheckCryptoPaymentUri: the scheme matches the asset and the URI pays
    /// exactly `address`. A URI that fails is neither shown nor opened.
    func checkPaymentUri(asset: String, uri: String, address: String) -> Bool
    /// CryptoAssetTicker: USDC, ZEC, XMR, TAO, BTC, ETH, SOL.
    func ticker(asset: String) -> String
    /// CryptoWalletSuggestions: the wallets that can pay the asset.
    func walletSuggestions(asset: String) -> [String]
    /// PaymentMethodAllowsPlan: false only for a coin with monthly.
    func allowsPlan(method: String, plan: String) -> Bool
    /// CryptoPaymentUriScheme: the scheme of the coin's payment URI, "" for a
    /// coin without one (TAO), whose invoice is paid by hand.
    func uriScheme(asset: String) -> String
    /// CryptoPaymentTabId: the tab a coin sits in (its own asset, or "More
    /// coins" for TAO, Bitcoin, ETH and SOL); "" for Card.
    func tabId(asset: String) -> String
    /// CryptoPaymentTabCoin: what a tap on `tab` chooses: `lastChosen` (the
    /// coin last chosen in the tab) while it can be paid with now, else
    /// `remembered` while it is one of the tab's payable coins, else the tab's
    /// first payable coin; "" for a tab with none.
    func tabCoin(_ tab: CryptoPayTab, lastChosen: String, remembered: String) -> String
    /// CryptoAssetLinesFor: the coin's network line, network-only warning and
    /// no-payment-link note.
    func lines(asset: String) -> CryptoAssetLines
    /// CryptoPaymentShowsMemo: a memo shows only when the server sent one
    /// (only USDC's has one; SOL's is "").
    func showsMemo(asset: String, memo: String) -> Bool
    /// CryptoPaymentSteps: the status steps at `status`, two for USDC and
    /// four for the other coins, a step the payment skipped drawn done; none
    /// for a status without steps.
    func steps(asset: String, status: String, confirmations: Int, confirmationsRequired: Int) -> [CryptoPaymentStepValue]
}

/// What the invoice view shows for a snapshot, top to bottom (CONTRACT §6.2).
/// The view turns each decision into its copy.
struct CryptoInvoiceDisplay: Equatable {

    enum Countdown: Equatable {
        /// "Quote expires in m:ss".
        case running(String)
        /// "This quote expired. Refresh it for a new amount."
        case expired
    }

    enum Refresh: Equatable {
        case hidden
        case available
        /// The requote is in flight.
        case inFlight
    }

    /// The status steps: waiting → payment seen → confirming n of N → paid.
    enum Step: Equatable {
        case waiting
        case seen
        case confirming(count: Int, required: Int)
        case paid
    }

    enum StepProgress: Equatable {
        case done
        case current
        case upcoming
    }

    struct StepRow: Equatable {
        var step: Step
        var progress: StepProgress
    }

    /// The invoice is being created (StartInvoice in flight).
    var isStarting: Bool = false
    var method: PaymentMethod? = nil
    /// The invoice's first line, the network the coin is sent on (the SDK's
    /// line: "USDC on Solana", "Zcash, shielded", "Monero", "Bittensor
    /// network", "Bitcoin network", "Ethereum mainnet", "Solana (native SOL)").
    var networkLine: CryptoPayLine? = nil
    /// With the address: only this coin, sent on this network, is credited
    /// (the SDK's line); none for Zcash and Monero.
    var networkWarning: CryptoPayLine? = nil
    /// Under the QR code of a coin without a payment link (TAO): it holds the
    /// address alone (the SDK's note).
    var noPaymentLinkNote: CryptoPayLine? = nil
    /// The server's payment URI for "Open in wallet": only while payable, and
    /// when the SDK's check passed (an empty uri shows none: TAO has none).
    var paymentUri: String? = nil
    /// What the QR code shows while payable (the SDK's QrText): the payment
    /// URI that passed the check, or for a coin without one (TAO) the address
    /// alone; never anything but what the screen shows.
    var qrText: String? = nil
    /// A coin without a payment link (TAO, the SDK's CryptoPaymentUriScheme
    /// is empty): "Send exactly this amount to this address." stands where
    /// Open in wallet would, the amount and the address have their own Copy
    /// amount and Copy address, and a note says the QR code holds the address
    /// alone.
    var hasNoPaymentLink: Bool = false
    /// "Send exactly": the amount with its ticker ("0.072387 XMR"), and the
    /// bare amount Copy copies.
    var amount: String? = nil
    var amountValue: String? = nil
    /// "To this address", with Copy, and the coin's network-only warning
    /// beside it.
    var address: String? = nil
    /// The reference memo for a transfer sent by hand, when the SDK shows it
    /// (CryptoPaymentShowsMemo: only a memo the server sent, which only USDC
    /// has).
    var memo: String? = nil
    var countdown: Countdown? = nil
    var refresh: Refresh = .hidden
    var steps: [StepRow] = []
    /// `seen` short of the amount: "{amount} more to send", with its ticker,
    /// and the bare amount Copy copies.
    var remaining: String? = nil
    var remainingValue: String? = nil
    /// `review`: the review copy and nothing else to do.
    var inReview: Bool = false
    /// The invoice failed: it could not be started, or the server no longer
    /// knows it (`unknown`). Another way is the way on.
    var isFailed: Bool = false
    /// A resumed invoice before its first poll (status ""): a brief loading
    /// line in place of the payment details; money may already be on its way.
    var isAwaitingStatus: Bool = false
    /// "Wallets that work: …".
    var wallets: [String] = []
    var showsZcashExchangeNote: Bool = false
    /// "Pay another way": while the server says nothing arrived, or the
    /// invoice failed; otherwise only Close.
    var showsPayAnotherWay: Bool = false
    var isPaid: Bool = false
    /// The last requote failed with asset_unavailable (the method's
    /// "temporarily unavailable" line).
    var unavailable: Bool = false

    init() {}

    /// What each state shows (CONTRACT §6.2.1, binding for every surface).
    init(_ snapshot: CryptoInvoiceSnapshot, catalog: CryptoPaymentCatalog) {
        let method = PaymentMethod(asset: snapshot.asset)
        self.method = method
        let lines = method == nil ? CryptoAssetLines.none : catalog.lines(asset: snapshot.asset)
        networkLine = lines.networkLine
        networkWarning = lines.networkWarning
        noPaymentLinkNote = lines.noPaymentLinkNote
        hasNoPaymentLink = method != nil && catalog.uriScheme(asset: snapshot.asset).isEmpty
        isPaid = snapshot.isPaid
        unavailable = snapshot.errorCode == CryptoPurchaseErrorCode.assetUnavailable

        if snapshot.phase == .starting {
            isStarting = true
            return
        }

        let status = snapshot.status
        if status == CryptoPaymentStatus.review {
            // nothing else to do: support sorts it out
            inReview = true
            return
        }
        if status == CryptoPaymentStatus.unknown || snapshot.phase == .failed {
            isFailed = true
            showsPayAnotherWay = true
            return
        }
        if status.isEmpty && !isPaid {
            // the SDK gives every new or requoted invoice `pending`: no status
            // is a resumed invoice not polled yet, possibly paid already
            isAwaitingStatus = true
            return
        }

        steps = Self.stepRows(catalog.steps(
            asset: snapshot.asset,
            status: snapshot.status,
            confirmations: snapshot.confirmations,
            confirmationsRequired: snapshot.confirmationsRequired
        ))
        if isPaid || status == CryptoPaymentStatus.confirming {
            // the payment arrived: nothing more to send
            return
        }

        // nothing received: a requote, and another way, are allowed
        if snapshot.isAwaitingPayment {
            refresh = snapshot.refreshing ? .inFlight : .available
            showsPayAnotherWay = true
        }

        let ticker = snapshot.ticker.isEmpty ? catalog.ticker(asset: snapshot.asset) : snapshot.ticker
        func withTicker(_ amount: String) -> String {
            ticker.isEmpty ? amount : "\(amount) \(ticker)"
        }
        let address = snapshot.address.isEmpty ? nil : snapshot.address

        switch status {
        case CryptoPaymentStatus.pending where 0 < snapshot.secondsLeft:
            // payable: the quote as the server built it
            countdown = .running(Self.countdownText(seconds: snapshot.secondsLeft))
            if !snapshot.amount.isEmpty {
                amount = withTicker(snapshot.amount)
                amountValue = snapshot.amount
            }
            self.address = address
            if let address, !snapshot.uri.isEmpty,
               catalog.checkPaymentUri(asset: snapshot.asset, uri: snapshot.uri, address: address) {
                paymentUri = snapshot.uri
            }
            // the code never pays anything but what the screen shows: the uri
            // that passed the check, or the address itself (a coin without a
            // payment uri)
            if let address, !snapshot.qrText.isEmpty,
               snapshot.qrText == address || (snapshot.qrText == snapshot.uri && paymentUri != nil) {
                qrText = snapshot.qrText
            }
            // a memo for a transfer sent by hand, when the server sent one
            if address != nil, catalog.showsMemo(asset: snapshot.asset, memo: snapshot.memo) {
                memo = snapshot.memo
            }
        case CryptoPaymentStatus.pending, CryptoPaymentStatus.expired:
            // the quote ran out: a stale amount must not be paid
            countdown = .expired
        case CryptoPaymentStatus.seen:
            // short of the amount: the rest goes to the same address. The
            // server's URI asks for the whole amount again, so neither it nor
            // the full amount shows: paying it would overpay.
            if let rest = Self.positiveAmount(snapshot.remaining) {
                remaining = withTicker(rest)
                remainingValue = rest
            }
            self.address = address
        default:
            // a status this app does not know: the steps alone
            return
        }

        wallets = catalog.walletSuggestions(asset: snapshot.asset)
        showsZcashExchangeNote = method == .zec
    }

    /// The step the invoice is at (the account screen's row says it).
    var currentStep: Step? {
        steps.first { $0.progress == .current }?.step ?? (isPaid ? .paid : nil)
    }

    /// The SDK's steps (CryptoPaymentSteps) as rows: USDC's waiting → paid,
    /// the other coins' waiting → seen → confirming n of N → paid, each done,
    /// current or upcoming as the SDK draws it (a step the payment skipped is
    /// done). A step this app does not know is left out.
    static func stepRows(_ steps: [CryptoPaymentStepValue]) -> [StepRow] {
        steps.compactMap { (value: CryptoPaymentStepValue) -> StepRow? in
            let step: Step
            switch value.status {
            case CryptoPaymentStatus.pending:
                step = .waiting
            case CryptoPaymentStatus.seen:
                step = .seen
            case CryptoPaymentStatus.confirming:
                step = .confirming(count: value.confirmations, required: value.confirmationsRequired)
            case CryptoPaymentStatus.paid:
                step = .paid
            default:
                return nil
            }
            let progress: StepProgress
            switch value.progress {
            case CryptoPaymentStepProgress.done:
                progress = .done
            case CryptoPaymentStepProgress.current:
                progress = .current
            default:
                progress = .upcoming
            }
            return StepRow(step: step, progress: progress)
        }
    }

    /// m:ss, for the countdown ("29:59", "0:05"; a 60-minute USDC quote reads "60:00").
    static func countdownText(seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The amount when it is a decimal above zero, as the server wrote it.
    static func positiveAmount(_ amount: String) -> String? {
        guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), value > 0 else {
            return nil
        }
        return amount
    }
}

// MARK: - the paid year's end

/// The balance's `crypto_term` (CONTRACT §2.2): the network's latest one-time
/// crypto credit whose grace has not ended. Whether its renewal notice shows
/// is the SDK's CryptoTermNoticeDue (CryptoPaymentSdk.termNoticeDue, CONTRACT
/// §4.4.1); the grace's end is parsed only to show it.
struct CryptoTerm: Equatable {
    var market: String
    /// When the paid term ends and the grace begins, RFC 3339.
    var termEndTime: String
    /// When the grace ends, and Pro with it, RFC 3339.
    var graceEndTime: String

    /// The grace's end, for "Renew by {date}"; nil when it does not parse.
    var graceEnd: Date? {
        parseRfc3339(graceEndTime)
    }
}

/// An RFC 3339 time as the server writes it (Go's time.Time: "Z" or an
/// offset, with or without fractional seconds, up to nanoseconds).
func parseRfc3339(_ text: String) -> Date? {
    let text = text.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else {
        return nil
    }
    // ISO8601DateFormatter reads at most milliseconds; drop the digits past them
    var trimmed = text
    if let dot = text.firstIndex(of: ".") {
        let fractionEnd = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
        let digits = text[text.index(after: dot)..<fractionEnd]
        trimmed = String(text[..<dot]) + (digits.isEmpty ? "" : "." + digits.prefix(3)) + String(text[fractionEnd...])
    }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: trimmed) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
}

// MARK: - the subscription's store

/// Whether the current subscription is a one-time crypto year (the SDK's
/// ClassifySubscriptionStore family "crypto": every coin's market, solana,
/// zcash, monero, bittensor, bitcoin and ethereum), which does not renew and
/// has nothing to manage in the Stripe portal.
func subscriptionStoreIsCrypto(_ storeClass: String) -> Bool {
    storeClass == "crypto"
}

// MARK: - the QR code

/// The QR code of an invoice's QR text, one pixel per module (the view scales
/// it without smoothing): the server's payment URI, shown only after the
/// SDK's check passed, or for a coin without one (TAO) the address alone.
/// Nil for an empty text or one the generator refuses.
func cryptoPaymentQrImage(_ uri: String) -> CGImage? {
    guard !uri.isEmpty, let data = uri.data(using: .utf8) else {
        return nil
    }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = data
    // M: a phone reads it from a screen at a glance; nothing covers modules
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else {
        return nil
    }
    return CIContext().createCGImage(output, from: output.extent)
}
