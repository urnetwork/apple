//
//  CryptoPayment.swift
//  URnetwork
//
//  The direct-download build's crypto payments (mmm/ZCASH-CONTRACT.md §4.3–§6,
//  mmm ZCASH.md §0.1/§0.3): the method row's rules and what an invoice shows,
//  decided from plain values so they are unit tested.
//
//  Pure: no SwiftUI and no strings, so it compiles in both builds (the unit
//  test host is the App Store app). The views and every crypto string compile
//  only under DIRECT_DOWNLOAD (Shared/Views/CryptoPay). The SDK owns the
//  methods list, the URI check, the tickers, the wallet names and the invoice
//  state machine (CryptoPaymentSdk.swift); nothing here re-derives them.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// MARK: - methods

/// A way to pay on the method row (CONTRACT §1 "method"): Card (Stripe), or a
/// coin, named by the asset it pays in. The raw values are the SDK's
/// (PaymentMethodCard, CryptoAsset*).
enum PaymentMethod: String, CaseIterable, Hashable {
    case card
    case usdcSolana = "usdc_solana"
    case zec
    case xmr

    // CaseIterable's order is the row's: Card · USDC · Zcash · Monero

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

    /// The store the offer and purchase events name (CONTRACT §6.1): Stripe
    /// for Card, the coin's market otherwise. The SDK's EventStore* values.
    var eventStore: String {
        switch self {
        case .card:
            return "stripe"
        case .usdcSolana:
            return "solana"
        case .zec:
            return "zcash"
        case .xmr:
            return "monero"
        }
    }

    /// The purchase events' product for a coin's year of Pro, as Android names
    /// the USDC one (`pro_yearly_usdc`).
    var eventProduct: String {
        switch self {
        case .card:
            return "pro"
        case .usdcSolana:
            return "pro_yearly_usdc"
        case .zec:
            return "pro_yearly_zec"
        case .xmr:
            return "pro_yearly_xmr"
        }
    }
}

/// The method row's rules (CONTRACT §6.1).
enum PaymentMethodRules {

    /// The plans the server sells for a coin (CONTRACT §1 "item").
    static let planYearly = "yearly"
    static let planYearlyOnboarding = "yearly_onboarding"
    static let planMonthly = "monthly"

    /// The methods a row lists, from the SDK's PaymentMethods for the item the
    /// coin would buy: Card first, then the coins this app knows, in the row's
    /// order. A method the SDK names that this app does not know is left out.
    static func methods(_ listed: [String]) -> [PaymentMethod] {
        let known = Set(listed.compactMap(PaymentMethod.init(rawValue:)))
        return PaymentMethod.allCases.filter { $0 == .card || known.contains($0) }
    }

    /// The row shows only when the server lists a coin; with Card alone the
    /// surface looks exactly as it did before crypto.
    static func showsRow(_ methods: [PaymentMethod]) -> Bool {
        methods.contains { $0.isCoin }
    }

    /// The selected method: the one remembered on this device when the row
    /// lists it, else Card (a remembered coin the server stopped listing falls
    /// back to Card).
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
    /// Card first, then the listed coins.
    var methods: [PaymentMethod]
    var selected: PaymentMethod
    /// The selected coin's last start failed with asset_unavailable: the row
    /// says "Temporarily unavailable" under it and the coin stays selectable.
    var selectedUnavailable: Bool
    /// The monthly plan can be bought with the selected method.
    var allowsMonthly: Bool

    var isShown: Bool {
        PaymentMethodRules.showsRow(methods)
    }

    /// Card, as every surface was before crypto.
    static let card = PaymentMethodRowState(methods: [.card], selected: .card, selectedUnavailable: false, allowsMonthly: true)
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

// MARK: - what the invoice shows

/// The SDK's pure helpers an invoice is drawn with (CONTRACT §4.3), behind a
/// protocol so the display decisions are tested without the SDK.
protocol CryptoPaymentCatalog {
    /// CheckCryptoPaymentUri: the scheme matches the asset and the URI pays
    /// exactly `address`. A URI that fails is neither shown nor opened.
    func checkPaymentUri(asset: String, uri: String, address: String) -> Bool
    /// CryptoAssetTicker: USDC, ZEC, XMR.
    func ticker(asset: String) -> String
    /// CryptoWalletSuggestions: the wallets that can pay the asset.
    func walletSuggestions(asset: String) -> [String]
    /// PaymentMethodAllowsPlan: false only for a coin with monthly.
    func allowsPlan(method: String, plan: String) -> Bool
}

/// What the invoice view shows for a snapshot, top to bottom (CONTRACT §6.2).
/// The view turns each decision into its copy.
struct CryptoInvoiceDisplay: Equatable {

    /// The invoice's first line: "USDC on Solana", "Zcash, shielded", "Monero".
    enum Network: Equatable {
        case usdcOnSolana
        case zcashShielded
        case monero
    }

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
    var network: Network? = nil
    /// The server's payment URI for the QR and "Open in wallet": only while
    /// payable, and when the SDK's check passed (an empty uri shows none).
    var paymentUri: String? = nil
    /// "Send exactly": the amount with its ticker ("0.072387 XMR"), and the
    /// bare amount Copy copies.
    var amount: String? = nil
    var amountValue: String? = nil
    /// "To this address", with Copy.
    var address: String? = nil
    /// USDC only: the reference memo for a transfer sent by hand.
    var memo: String? = nil
    /// USDC only: the existing "Send USDC on the Solana network only" warning.
    var showsUsdcNetworkWarning: Bool = false
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
        network = method.flatMap(Self.networkLine(for:))
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

        steps = Self.steps(snapshot)
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
            if method == .usdcSolana, address != nil, !snapshot.memo.isEmpty {
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

        showsUsdcNetworkWarning = method == .usdcSolana && self.address != nil
        wallets = catalog.walletSuggestions(asset: snapshot.asset)
        showsZcashExchangeNote = method == .zec
    }

    /// The step the invoice is at (the account screen's row says it).
    var currentStep: Step? {
        steps.first { $0.progress == .current }?.step ?? (isPaid ? .paid : nil)
    }

    static func networkLine(for method: PaymentMethod) -> Network? {
        switch method {
        case .card:
            return nil
        case .usdcSolana:
            return .usdcOnSolana
        case .zec:
            return .zcashShielded
        case .xmr:
            return .monero
        }
    }

    /// The steps for the snapshot's status. USDC reports only pending, paid
    /// and expired (CONTRACT §2.5), so its steps are waiting → paid.
    static func steps(_ snapshot: CryptoInvoiceSnapshot) -> [StepRow] {
        let confirming = Step.confirming(count: snapshot.confirmations, required: snapshot.confirmationsRequired)
        let all: [Step] = PaymentMethod(asset: snapshot.asset) == .usdcSolana
            ? [.waiting, .paid]
            : [.waiting, .seen, confirming, .paid]
        let current: Int
        if snapshot.isPaid {
            current = all.count - 1
        } else {
            switch snapshot.status {
            case CryptoPaymentStatus.seen:
                current = 1
            case CryptoPaymentStatus.confirming:
                current = all.count == 4 ? 2 : 0
            default:
                current = 0
            }
        }
        return all.enumerated().map { index, step in
            let progress: StepProgress
            if index < current || (snapshot.isPaid && index == current) {
                progress = .done
            } else if index == current {
                progress = .current
            } else {
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
/// ClassifySubscriptionStore family "crypto": solana, monero, zcash), which
/// does not renew and has nothing to manage in the Stripe portal.
func subscriptionStoreIsCrypto(_ storeClass: String) -> Bool {
    storeClass == "crypto"
}

// MARK: - the QR code

/// The QR code of a payment URI, one pixel per module (the view scales it
/// without smoothing). Nil for an empty URI or one the generator refuses.
/// The URI is the server's, shown only after the SDK's check passed.
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
