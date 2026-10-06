//
//  GuestPurchaseRefusalTests.swift
//  networkTests
//
//  The server refuses a Stripe payment sheet or checkout session for a legacy
//  guest network with error.code guest_sign_in_required (server
//  refuseGuestPurchase). That refusal opens the add-sign-in sheet
//  (GuestPurchaseGate) instead of an error: a refreshed guest reads as an
//  account until the balance reports it, so the app could get this far.
//
//  Every other refusal keeps its code and message, and the purchase words
//  the code the way ur.io's payment screens do (CheckoutRefusal, as
//  paymentFailure.js): a code with a line reads that translated line alone,
//  invalid_request and start_failed the screen's own line, and any other
//  code, or none, the screen's own line with the server's words under it.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct GuestPurchaseRefusalTests {

    private static let message = "Add a sign-in to your account before buying a plan."

    @Test func theGuestCodeIsTheSignInRefusal() {
        #expect(SdkPurchaseErrorCodeGuestSignInRequired == "guest_sign_in_required")
        #expect(StripeBillingError.refused(code: "guest_sign_in_required", message: Self.message) == .guestSignInRequired)
    }

    @Test func otherRefusalsKeepTheirCodeAndMessage() {
        // an older server sends no code; codes compare exactly
        #expect(StripeBillingError.refused(code: "", message: "Unknown plan.") == .refusal(code: "", message: "Unknown plan."))
        #expect(StripeBillingError.refused(code: "GUEST_SIGN_IN_REQUIRED", message: Self.message) == .refusal(code: "GUEST_SIGN_IN_REQUIRED", message: Self.message))
        #expect(StripeBillingError.refused(code: "already_subscribed", message: "Already subscribed.") == .refusal(code: "already_subscribed", message: "Already subscribed."))
    }

    // MARK: the words for a refusal's code

    private static let screenLine = "The screen's own line."
    private static let words = "The server's own words."

    /// The codes with a line of their own, and the line's source (its English).
    private static let lines = [
        ("already_subscribed", "You already have Pro, so nothing was charged. Manage your subscription from your account."),
        ("plan_unavailable", "This plan is not available right now. Try again later."),
        ("checkout_unavailable", "Checkout isn't available right now. Please try again later."),
    ]

    @Test func aCodeWithALineReadsThatLineAlone() {
        #expect(CheckoutRefusal.message(code: "already_subscribed", words: Self.words, screenLine: Self.screenLine)
            == String(localized: "You already have Pro, so nothing was charged. Manage your subscription from your account."))
        #expect(CheckoutRefusal.message(code: "plan_unavailable", words: Self.words, screenLine: Self.screenLine)
            == String(localized: "This plan is not available right now. Try again later."))
        #expect(CheckoutRefusal.message(code: "checkout_unavailable", words: Self.words, screenLine: Self.screenLine)
            == String(localized: "Checkout isn't available right now. Please try again later."))
    }

    @Test func invalidRequestAndStartFailedReadTheScreensLineAlone() {
        // a client defect, and a start to try again
        for code in ["invalid_request", "start_failed"] {
            #expect(CheckoutRefusal.message(code: code, words: Self.words, screenLine: Self.screenLine) == Self.screenLine, "\(code)")
        }
    }

    @Test func anyOtherCodeOrNoneReadsTheScreensLineWithTheServersWords() {
        // no code from an older server, codes without a line here, and codes
        // that match one only when case is ignored
        for code in ["", "rate_limited", "item_unavailable", "offer_unavailable", "ALREADY_SUBSCRIBED", "Start_Failed"] {
            #expect(CheckoutRefusal.message(code: code, words: Self.words, screenLine: Self.screenLine)
                == "The screen's own line.\nThe server's own words.", "\(code)")
        }
        // nothing goes under the line when the server said nothing more
        #expect(CheckoutRefusal.message(code: "", words: "", screenLine: Self.screenLine) == Self.screenLine)
        #expect(CheckoutRefusal.message(code: "", words: Self.screenLine, screenLine: Self.screenLine) == Self.screenLine)
    }

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    private static func value(_ localizations: [String: Any], _ locale: String) -> String? {
        let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    /// The lines come from the localizations store, translated for every
    /// locale the catalog ships.
    @Test func theLinesAreTranslatedInEveryLocale() throws {
        let strings = try Self.catalogStrings()
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))

        for (code, source) in Self.lines {
            let entry = try #require(strings[source] as? [String: Any], "the catalog has no line for \(code)")
            #expect(entry["extractionState"] as? String != "stale")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            var missing: [String] = []
            for locale in locales.sorted() {
                guard let value = Self.value(localizations, locale), !value.isEmpty else {
                    missing.append(locale)
                    continue
                }
                if locale != "en" {
                    #expect(value != source, "\(code): \(locale) is English")
                }
            }
            #expect(missing.isEmpty, "\(code) is not translated: \(missing)")
        }
    }

    @MainActor
    private final class IdleConfirmation: PurchaseConfirming {
        var onStateChanged: ((String) -> Void)?
        func start() {}
        func stop() {}
        func setForeground(_ foreground: Bool) {}
        func startPurchaseConfirmation() {}
    }

    @Test func theRefusalMarksTheNetworkAGuest() {
        // isPro keeps the 30 s background poll (a real timer) out of the test
        let viewModel = SubscriptionBalanceViewModel(
            urApiService: MockUrApiService(),
            isPro: true,
            refreshJwt: {},
            purchaseConfirmation: IdleConfirmation()
        )
        // a refreshed guest: no claim, and the balance has not said so yet
        #expect(GuestAccount.purchaseEntry(isGuest: GuestAccount.isGuest(guestModeClaim: false, serverGuest: viewModel.isGuest)) == .checkout)

        viewModel.serverRefusedGuestPurchase()

        #expect(viewModel.isGuest)
        #expect(GuestAccount.purchaseEntry(isGuest: GuestAccount.isGuest(guestModeClaim: false, serverGuest: viewModel.isGuest)) == .addSignInMethod)
    }

    // …/apple/app/networkTests/GuestPurchaseRefusalTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The refusal reaches the gates: MainView marks the network a guest (the
    /// upgrade sheet and the offer sheet are behind GuestPurchaseGate), and the
    /// intro, which sells a plan without a gate, opens the upgrade sheet.
    @Test func theRefusalReachesTheGates() throws {
        let client = try Self.source("network/Shared/Billing/StripeBillingClient.swift")
        #expect(client.components(separatedBy: "throw StripeBillingError.refused(code: error.code, message: error.message)").count - 1 == 2)

        let main = try Self.source("network/Main/MainView.swift")
        let mainChange = try #require(main.range(of: ".onChange(of: stripeSubscriptionStore.guestSignInRequiredSequence)"))
        #expect(main.range(of: "subscriptionBalanceViewModel.serverRefusedGuestPurchase()", range: mainChange.upperBound..<main.endIndex) != nil)

        let intro = try Self.source("network/Shared/Views/Introduction/IntroductionView.swift")
        let introChange = try #require(intro.range(of: ".onChange(of: stripeSubscriptionStore.guestSignInRequiredSequence)"))
        #expect(intro.range(of: "openGuestConversion()", range: introChange.upperBound..<intro.endIndex) != nil)
    }
}
