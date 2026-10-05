//
//  StripeSubscriptionStore.swift
//  URnetwork
//
//  The direct-download build's SubscriptionStore: Pro billed through Stripe,
//  mirroring the Windows and Linux apps (BalanceSheets.cpp / UpgradeSheet.cpp).
//
//  Prices come from GET /subscription/stripe/prices. A purchase tries, in
//  order, and falls through only while nothing has rendered yet (so no
//  payment can be lost by switching):
//    1. the inline pay sheet: POST /subscription/stripe/payment-sheet, then
//       ur.io/app/pay-sheet in the web view, which posts {type:"ur-pay",status}
//       to the `urpay` handler and/or navigates to urnetwork://pay/done;
//    2. an embedded checkout session (ui_mode embedded, redirect_on_completion
//       never) on ur.io/checkout, which navigates to
//       urnetwork://checkout?status=complete|errorCode= (complete from
//       Stripe's onComplete, in place);
//    3. the hosted checkout URL in the default browser.
//  Paid in any of them, the server only believes the Stripe webhook, so the
//  caller's onSuccess starts the same confirmation poll StoreKit uses.
//  Manage/cancel is the Stripe customer portal, opened in the browser.
//

import Combine
import Foundation
import SwiftUI
import URnetworkSdk
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A checkout page open in the sheet's web view.
struct StripeCheckoutRequest: Equatable, Identifiable {
    enum Stage: Equatable {
        case paySheet
        case embedded
    }

    let id: Int
    let stage: Stage
    let url: URL
}

@MainActor
final class StripeSubscriptionStore: ObservableObject, SubscriptionStore {

    var storeName: String { SdkEventStoreStripe }
    let distribution: BillingDistribution = .direct

    @Published private(set) var prices: StripePlanPrices?
    @Published private(set) var plansLoadFailed: Bool = false

    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var purchaseSuccess: Bool = false
    /// Stripe has no Ask to Buy; a purchase is never pending.
    let purchasePending: Bool = false
    @Published private(set) var purchaseError: String?
    @Published private(set) var purchaseConfirmingTitle: String?
    @Published private(set) var purchaseConfirmingMessage: String?
    /// The checkout page to show, while one is open.
    @Published private(set) var checkout: StripeCheckoutRequest?
    /// The last hosted checkout URL handed to the browser (for the "opened in browser" state).
    private(set) var openedInBrowser: URL?
    /// Bumped when the server refused a purchase because the network is a
    /// legacy guest (`guest_sign_in_required`): MainView marks the network a
    /// guest, so the purchase's GuestPurchaseGate opens the add-sign-in sheet.
    @Published private(set) var guestSignInRequiredSequence: Int = 0

    /// Stripe has no restore; "restore" re-checks the plan with the server.
    let isRestoringPurchases: Bool = false
    @Published private(set) var restoreResultMessage: String?

    private let client: StripeBillingClient
    /// Opens a URL in the default browser; true when it was handed off.
    private let openExternal: (URL) -> Bool

    private var onPurchaseSuccess: (() -> Void)?
    /// Bumped per purchase attempt: an answer for an earlier attempt is dropped.
    private var attempt: Int = 0
    private var plan: PaymentOption = .yearly
    /// The started/completed/cancelled/failed pair: one terminal event per attempt.
    private var outcomeEmitted: Bool = false
    /// A page that failed to load falls back once per stage.
    private var loadFallbackTried: Bool = false
    private var isLoadingPrices: Bool = false

    init(client: StripeBillingClient, openExternal: ((URL) -> Bool)? = nil) {
        self.client = client
        self.openExternal = openExternal ?? Self.openInDefaultBrowser
    }

    convenience init(api: SdkApi?) {
        self.init(client: SdkStripeBillingClient(api: api))
    }

    static func openInDefaultBrowser(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        return true
        #else
        return false
        #endif
    }

    // MARK: plans

    func presentation(tier: PlanTier?, offer: PlanOffer?, storefrontCountryName: String?) -> PlanPresentation? {
        guard let prices else {
            // list prices from the tier until the server answers, no trial promised
            return .resolve(tier: tier, offer: nil, storeMonthly: nil, storeYearly: nil, trialDays: nil, equivalent: nil, storefrontCountryName: storefrontCountryName)
        }
        return .stripe(prices: prices, tier: tier, offer: offer, storefrontCountryName: storefrontCountryName)
    }

    /// The prices say the caller may redeem the welcome offer's coupon (the
    /// onboarding offer page and the email link's offer sheet are shown only
    /// then; false until the prices arrive).
    var offerEligible: Bool {
        prices?.offerEligible ?? false
    }

    func retryLoadPlansIfNeeded(storefrontCountry: String?) {
        guard prices == nil else {
            return
        }
        Task {
            await loadPrices(storefrontCountry: storefrontCountry)
        }
    }

    func loadPrices(storefrontCountry: String?) async {
        guard !isLoadingPrices else {
            return
        }
        isLoadingPrices = true
        defer { isLoadingPrices = false }
        do {
            let prices = try await client.prices(storefrontCountry: storefrontCountry)
            self.prices = prices
            self.plansLoadFailed = false
        } catch {
            print("[StripeSubscriptionStore] prices failed: \(error)")
            self.plansLoadFailed = true
        }
    }

    // MARK: purchase

    private var eventProduct: String { StripeCheckoutLinks.itemId(for: plan) }
    private var eventPlan: String { StripeCheckoutLinks.planName(for: plan) }
    private var eventPrice: Double {
        guard let prices else { return -1 }
        return plan == .monthly ? prices.monthlyUsd : prices.yearlyUsd
    }
    private var eventCurrency: String { prices?.currency.uppercased() ?? "" }

    func purchase(plan: PaymentOption, onSuccess: @escaping () -> Void) async {
        guard !isPurchasing else {
            return
        }
        attempt += 1
        let attempt = self.attempt
        self.plan = plan
        isPurchasing = true
        purchaseSuccess = false
        purchaseError = nil
        purchaseConfirmingTitle = nil
        purchaseConfirmingMessage = nil
        restoreResultMessage = nil
        checkout = nil
        openedInBrowser = nil
        outcomeEmitted = false
        loadFallbackTried = false
        onPurchaseSuccess = onSuccess
        ClientEvents.shared.purchaseStarted(store: storeName, product: eventProduct, plan: eventPlan, trial: false, price: eventPrice, currency: eventCurrency)

        // 1. the inline pay sheet
        do {
            let sheet = try await client.paymentSheet(plan: eventPlan, storefrontCountry: nil)
            guard attempt == self.attempt else { return }
            if let secret = StripeCheckoutLinks.intentClientSecret(setup: sheet.setupIntentClientSecret, payment: sheet.paymentIntentClientSecret),
               let url = StripeCheckoutLinks.paySheetURL(clientSecret: secret, publishableKey: sheet.publishableKey, plan: eventPlan) {
                checkout = StripeCheckoutRequest(id: attempt, stage: .paySheet, url: url)
                return
            }
        } catch StripeBillingError.guestSignInRequired {
            guard attempt == self.attempt else { return }
            refuseForGuest()
            return
        } catch {
            guard attempt == self.attempt else { return }
            print("[StripeSubscriptionStore] payment sheet failed: \(error)")
        }
        // nothing rendered yet: the embedded checkout session saves the purchase
        await openEmbeddedCheckout(attempt: attempt)
    }

    /// The welcome offer is the yearly plan: the server applies the welcome
    /// coupon to the pay sheet's subscription (and to a checkout session)
    /// whenever the caller's offer is redeemable, which is what the prices
    /// said when the surface showed the offer. There is no code to enter.
    func redeemOffer(_ offer: PlanOffer, onSuccess: @escaping () -> Void) async {
        await purchase(plan: .yearly, onSuccess: onSuccess)
    }

    /// 2. the embedded checkout page; any failure retries once as hosted.
    private func openEmbeddedCheckout(attempt: Int) async {
        do {
            let session = try await client.checkoutSession(itemId: eventProduct, uiMode: SdkStripeUiModeEmbedded, redirectOnCompletion: SdkStripeRedirectOnCompletionNever, storefrontCountry: nil)
            guard attempt == self.attempt else { return }
            if let url = StripeCheckoutLinks.embeddedCheckoutURL(clientSecret: session.clientSecret) {
                loadFallbackTried = false
                checkout = StripeCheckoutRequest(id: attempt, stage: .embedded, url: url)
                return
            }
        } catch StripeBillingError.guestSignInRequired {
            guard attempt == self.attempt else { return }
            refuseForGuest()
            return
        } catch {
            guard attempt == self.attempt else { return }
            print("[StripeSubscriptionStore] embedded checkout failed: \(error)")
        }
        await openHostedCheckout(attempt: attempt)
    }

    /// 3. hosted checkout in the default browser, then the confirmation poll
    /// so Pro flips the moment the webhook lands.
    private func openHostedCheckout(attempt: Int) async {
        do {
            let session = try await client.checkoutSession(itemId: eventProduct, uiMode: SdkStripeUiModeHosted, redirectOnCompletion: "", storefrontCountry: nil)
            guard attempt == self.attempt else { return }
            guard !session.checkoutUrl.isEmpty, let url = URL(string: session.checkoutUrl), openExternal(url) else {
                fail(message: nil, errorClass: "transport")
                return
            }
            checkout = nil
            openedInBrowser = url
            purchaseConfirmingTitle = String(localized: "Finish in your browser.")
            purchaseConfirmingMessage = String(localized: "Complete your purchase in the browser. Your plan updates here automatically once payment is confirmed.")
            purchaseSuccess = true
            isPurchasing = false
            onPurchaseSuccess?()
        } catch StripeBillingError.guestSignInRequired {
            guard attempt == self.attempt else { return }
            refuseForGuest()
        } catch {
            guard attempt == self.attempt else { return }
            let message: String?
            if case StripeBillingError.server(let text) = error, !text.isEmpty {
                message = text
            } else {
                message = nil
            }
            fail(message: message, errorClass: "transport")
        }
    }

    // MARK: the checkout page's signals

    /// The pay page posted `{type:"ur-pay", status}` to the `urpay` handler.
    func handlePayMessage(_ body: Any) {
        guard let checkout, checkout.stage == .paySheet,
              let outcome = StripeCheckoutLinks.paySheetOutcome(message: body) else {
            return
        }
        switch outcome {
        case .succeeded:
            handle(.payDone)
        case .cancelled:
            cancelCheckout()
        case .failed(let message):
            handle(.payError(message: message))
        }
    }

    /// The page navigated to a urnetwork:// return (from the web view or the
    /// browser via NetworkApp.onOpenURL). True when it confirmed a purchase:
    /// the caller starts the confirmation poll.
    @discardableResult
    func handle(_ link: BillingDeepLink) -> Bool {
        if link.isConfirmed {
            // paid — in the web view, or in the browser handing control back —
            // the server only believes the Stripe webhook, so bridge the gap
            // with the confirmation poll exactly like hosted
            if isPurchasing || checkout != nil || openedInBrowser != nil {
                if !outcomeEmitted {
                    outcomeEmitted = true
                    ClientEvents.shared.purchaseCompleted(store: storeName, product: eventProduct, plan: eventPlan, trial: false, price: eventPrice, currency: eventCurrency)
                }
                checkout = nil
                openedInBrowser = nil
                isPurchasing = false
                purchaseConfirmingTitle = nil
                purchaseConfirmingMessage = String(localized: "We're confirming your purchase. Your plan will update automatically.")
                purchaseSuccess = true
            }
            onPurchaseSuccess?()
            return true
        }
        // a stale error after close is not an error
        guard isPurchasing || checkout != nil else {
            return false
        }
        fail(message: link.errorMessage, errorClass: checkout?.stage == .paySheet ? "payment_sheet" : "checkout")
        return false
    }

    /// The checkout page could not load at all (offline web view, TLS failure).
    /// Nothing rendered, so nothing was paid: the pay page falls back to the
    /// embedded checkout page, that to the browser. Once per stage.
    func handleLoadFailed() {
        guard let checkout, !loadFallbackTried else {
            return
        }
        loadFallbackTried = true
        let attempt = self.attempt
        self.checkout = nil
        Task {
            switch checkout.stage {
            case .paySheet:
                await openEmbeddedCheckout(attempt: attempt)
            case .embedded:
                await openHostedCheckout(attempt: attempt)
            }
        }
    }

    /// The web content process died: it cannot take a payment.
    func handleProcessTerminated() {
        guard checkout != nil else {
            return
        }
        fail(message: nil, errorClass: "web_process")
    }

    /// The user closed the checkout page.
    func cancelCheckout() {
        guard checkout != nil || isPurchasing else {
            return
        }
        if !outcomeEmitted {
            outcomeEmitted = true
            ClientEvents.shared.purchaseCancelled(store: storeName, product: eventProduct, plan: eventPlan, trial: false, price: eventPrice, currency: eventCurrency)
        }
        attempt += 1
        checkout = nil
        isPurchasing = false
    }

    /// The server refused the purchase because the network is a legacy guest
    /// (`guest_sign_in_required`). No fallback can sell it a plan and it is
    /// not an error to show: the add-sign-in sheet opens instead
    /// (guestSignInRequiredSequence).
    private func refuseForGuest() {
        if !outcomeEmitted {
            outcomeEmitted = true
            ClientEvents.shared.purchaseFailed(store: storeName, product: eventProduct, plan: eventPlan, trial: false, price: eventPrice, currency: eventCurrency, errorClass: SdkPurchaseErrorCodeGuestSignInRequired)
        }
        attempt += 1
        checkout = nil
        isPurchasing = false
        guestSignInRequiredSequence += 1
    }

    private func fail(message: String?, errorClass: String) {
        if !outcomeEmitted {
            outcomeEmitted = true
            ClientEvents.shared.purchaseFailed(store: storeName, product: eventProduct, plan: eventPlan, trial: false, price: eventPrice, currency: eventCurrency, errorClass: errorClass)
        }
        attempt += 1
        checkout = nil
        isPurchasing = false
        purchaseError = (message?.isEmpty == false ? message : nil) ?? String(localized: "Something went wrong. Please try again later.")
    }

    func resetPurchaseState() {
        // publish only what actually changes: the sheets that call this also
        // observe these values
        if purchaseSuccess { purchaseSuccess = false }
        if purchaseError != nil { purchaseError = nil }
        if purchaseConfirmingTitle != nil { purchaseConfirmingTitle = nil }
        if purchaseConfirmingMessage != nil { purchaseConfirmingMessage = nil }
        if restoreResultMessage != nil { restoreResultMessage = nil }
        if checkout != nil {
            cancelCheckout()
        }
        openedInBrowser = nil
    }

    // MARK: restore

    /// There is nothing to restore from Stripe; the server is the record. The
    /// caller re-runs the confirmation poll on `.restored`.
    func restorePurchases() async -> RestorePurchasesOutcome {
        restoreResultMessage = String(localized: "Checking your plan again.")
        return .restored
    }

    // MARK: manage

    /// The Stripe customer portal (change or cancel the plan), for the browser.
    func customerPortalURL() async throws -> URL {
        try await client.customerPortalURL()
    }

    // MARK: the sheet's checkout view

    var checkoutView: AnyView? {
        #if os(macOS)
        guard let checkout else {
            return nil
        }
        return AnyView(StripeCheckoutView(request: checkout, store: self))
        #else
        return nil
        #endif
    }
}
