import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// The direct-download build's Stripe purchase flow: pay sheet, then embedded
/// checkout, then the hosted page in the browser; the returns; manage.
struct StripeSubscriptionStoreTests {

    /// A server whose answers the test scripts.
    final class FakeClient: StripeBillingClient {
        var prices: Result<StripePlanPrices, Error> = .success(StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: false))
        var paymentSheet: Result<StripePaymentSheetResponse, Error> = .failure(StripeBillingError.unavailable)
        var embedded: Result<StripeCheckoutSessionResponse, Error> = .failure(StripeBillingError.unavailable)
        var hosted: Result<StripeCheckoutSessionResponse, Error> = .failure(StripeBillingError.unavailable)
        var portal: Result<URL, Error> = .failure(StripeBillingError.unavailable)
        var calls: [String] = []
        /// The payments reported, in order, and each report's answer to give.
        var reports: [StripePurchaseId] = []
        var reportDones: [(StripePurchaseReport?) -> Void] = []

        func prices(storefrontCountry: String?) async throws -> StripePlanPrices {
            calls.append("prices")
            return try prices.get()
        }

        func paymentSheet(plan: String, storefrontCountry: String?) async throws -> StripePaymentSheetResponse {
            calls.append("paymentSheet:\(plan)")
            return try paymentSheet.get()
        }

        func checkoutSession(itemId: String, uiMode: String, redirectOnCompletion: String, storefrontCountry: String?) async throws -> StripeCheckoutSessionResponse {
            calls.append("session:\(itemId):\(uiMode)" + (redirectOnCompletion.isEmpty ? "" : ":\(redirectOnCompletion)"))
            return try (uiMode == "embedded" ? embedded : hosted).get()
        }

        func customerPortalURL() async throws -> URL {
            calls.append("portal")
            return try portal.get()
        }

        func reportStripePurchase(_ purchaseId: StripePurchaseId, done: @escaping (StripePurchaseReport?) -> Void) {
            reports.append(purchaseId)
            reportDones.append(done)
        }
    }

    @MainActor
    private static func store(_ client: FakeClient, opened: @escaping (URL) -> Bool = { _ in true }) -> StripeSubscriptionStore {
        StripeSubscriptionStore(client: client, openExternal: opened)
    }

    @Test @MainActor func theStoreIsStripe() {
        let store = Self.store(FakeClient())
        #expect(store.storeName == "stripe")
        #expect(store.distribution == .direct)
        #expect(BillingDistribution.current == .appStore, "the tests build without DIRECT_DOWNLOAD")
    }

    @Test @MainActor func thePlansRenderFromTheTierUntilThePricesArriveAndPromiseNoTrial() async {
        let client = FakeClient()
        let store = Self.store(client)
        let before = store.presentation(tier: .standard, offer: nil, storefrontCountryName: nil)
        #expect(before?.yearlyTitle == "$39.99/year")
        #expect(before?.trialDays == nil)

        await store.loadPrices(storefrontCountry: "US")
        #expect(!store.plansLoadFailed)
        let after = store.presentation(tier: .standard, offer: nil, storefrontCountryName: nil)
        #expect(after?.yearlyTitle == "$40.00/year")
        #expect(after?.trialDays == nil)
    }

    @Test @MainActor func aPricesFailureOffersARetry() async {
        let client = FakeClient()
        client.prices = .failure(StripeBillingError.unavailable)
        let store = Self.store(client)
        await store.loadPrices(storefrontCountry: nil)
        #expect(store.plansLoadFailed)
        // the sheet's retry asks again...
        client.prices = .success(StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: false))
        await store.loadPrices(storefrontCountry: nil)
        #expect(!store.plansLoadFailed)
        #expect(client.calls == ["prices", "prices"])
        // ...and a store with prices does not
        store.retryLoadPlansIfNeeded(storefrontCountry: nil)
        await Self.settle()
        #expect(client.calls == ["prices", "prices"])
    }

    @Test @MainActor func thePaySheetOpensFirstWithTheSetupIntent() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_secret", paymentIntentClientSecret: "pi_secret", publishableKey: "pk_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.isPurchasing)
        #expect(store.checkout?.stage == .paySheet)
        #expect(store.checkout?.url.absoluteString
            == "https://ur.io/app/pay-sheet?cs=seti_secret&pk=pk_1&plan=yearly&return=urnetwork%3A%2F%2Fpay%2Fdone")
        #expect(client.calls == ["paymentSheet:yearly"])
    }

    @Test @MainActor func thePaySheetsSuccessMessageConfirmsAndStartsThePoll() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(paymentIntentClientSecret: "pi_secret", publishableKey: "pk_1"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .monthly, onSuccess: { polled += 1 })
        #expect(store.checkout?.url.absoluteString.contains("cs=pi_secret&pk=pk_1&plan=monthly") == true)

        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        #expect(polled == 1)
        #expect(store.purchaseSuccess)
        #expect(!store.isPurchasing)
        #expect(store.checkout == nil)
        #expect(store.purchaseConfirmingMessage == "We're confirming your purchase. Your plan will update automatically.")
        #expect(store.purchaseConfirmingTitle == nil)
    }

    @Test @MainActor func thePaySheetsReturnURLConfirmsToo() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(store.handle(.payDone))
        #expect(polled == 1)
        #expect(store.purchaseSuccess)
        #expect(store.checkout == nil)
    }

    @Test @MainActor func cancellingThePaySheetReturnsToThePlans() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        store.handlePayMessage(["type": "ur-pay", "status": "cancelled"])
        #expect(!store.isPurchasing)
        #expect(!store.purchaseSuccess)
        #expect(store.purchaseError == nil)
        #expect(store.checkout == nil)
        #expect(polled == 0)
        // a stale return after the close changes nothing
        #expect(!store.handle(.payError(message: "late")))
        #expect(store.purchaseError == nil)
    }

    @Test @MainActor func aPaySheetFailureRendersItsMessage() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.handlePayMessage(["type": "ur-pay", "status": "failed", "message": "Your card was declined."])
        #expect(store.purchaseError == "Your card was declined.")
        #expect(!store.isPurchasing)
        #expect(store.checkout == nil)

        // and one without a message says something generic
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.purchaseError == nil, "a new attempt starts clean")
        store.handle(.checkoutFailed(code: "-1", message: nil))
        #expect(store.purchaseError == "Something went wrong. Please try again later.")
    }

    // the embedded checkout page's failure, with its code, reaches the plans in
    // this app's words for a code it knows and in the page's text for any other
    @Test @MainActor func anEmbeddedCheckoutFailureReadsInTheAppsWords() async throws {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.server("no sheet"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret"))
        let store = Self.store(client)
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(store.checkout?.stage == .embedded)
        let link = BillingDeepLink(url: URL(string: "urnetwork://checkout?errorCode=checkout_unavailable&errorMessage=Checkout+is+not+configured.")!)
        #expect(store.handle(try #require(link)) == false)
        #expect(store.purchaseError == String(localized: "Checkout isn't available right now. Please try again later."))
        #expect(!store.isPurchasing)

        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(store.checkout?.stage == .embedded)
        store.handle(.checkoutFailed(code: SdkCheckoutBridgeErrorCheckout, message: "The checkout session is not valid."))
        #expect(store.purchaseError == "The checkout session is not valid.")
    }

    @Test @MainActor func noPaySheetFallsBackToTheEmbeddedCheckout() async {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.server("no sheet"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret"))
        let store = Self.store(client)
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(store.checkout?.stage == .embedded)
        #expect(store.checkout?.url.absoluteString
            == "https://ur.io/checkout?client_secret=cs_secret&redirect_link=urnetwork%3A%2F%2Fcheckout&redirect_on_completion=never")
        // a "never" session: Stripe fires onComplete on the bridge, which hands back in place
        #expect(client.calls == ["paymentSheet:monthly", "session:pro_monthly:embedded:never"])

        store.handle(.checkoutComplete(sessionId: "cs_1"))
        #expect(store.purchaseSuccess)
        #expect(store.checkout == nil)
    }

    @Test @MainActor func aPaySheetWithoutASecretFallsBackToo() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(publishableKey: "pk"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.checkout?.stage == .embedded)
    }

    @Test @MainActor func noEmbeddedSessionFallsBackToTheHostedPageInTheBrowser() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.stripe.com/c/pay/cs_1"))
        var opened: [URL] = []
        let store = Self.store(client, opened: { opened.append($0); return true })
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(client.calls == ["paymentSheet:yearly", "session:pro_yearly:embedded:never", "session:pro_yearly:hosted"])
        #expect(opened.map(\.absoluteString) == ["https://checkout.stripe.com/c/pay/cs_1"])
        #expect(store.checkout == nil)
        // the browser has it: the sheet waits on the poll with the browser copy
        #expect(polled == 1)
        #expect(store.purchaseSuccess)
        #expect(!store.isPurchasing)
        #expect(store.purchaseConfirmingTitle == "Finish in your browser.")
        #expect(store.purchaseConfirmingMessage == "Complete your purchase in the browser. Your plan updates here automatically once payment is confirmed.")

        // the browser handing control back confirms again (the poll guards its own restart)
        #expect(store.handle(.checkoutComplete(sessionId: "cs_1")))
        #expect(polled == 2)
    }

    @Test @MainActor func everythingFailingRendersTheSheetsLineWithTheServersWords() async {
        let client = FakeClient()
        // an older server's refusal has no code
        client.hosted = .failure(StripeBillingError.refused(code: "", message: "Billing is unavailable in your region."))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.purchaseError == "Something went wrong. Please try again later.\nBilling is unavailable in your region.")
        #expect(!store.isPurchasing)
        #expect(!store.purchaseSuccess)

        // no answer at all: the sheet's line alone
        client.hosted = .failure(StripeBillingError.unavailable)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.purchaseError == "Something went wrong. Please try again later.")
    }

    // MARK: a refused checkout session

    /// The hosted session is the last stage, so its refusal is the one the
    /// sheet shows: this app's line for a code that has one, the sheet's own
    /// line for invalid_request and start_failed, and the sheet's own line
    /// with the server's words under it for any other code.
    @Test @MainActor func aHostedRefusalReadsInTheAppsWordsForItsCode() async {
        let words = "The server's own words."
        let screenLine = String(localized: "Something went wrong. Please try again later.")
        let cases = [
            ("already_subscribed", String(localized: "You already have Pro, so nothing was charged. Manage your subscription from your account.")),
            ("plan_unavailable", String(localized: "This plan is not available right now. Try again later.")),
            ("checkout_unavailable", String(localized: "Checkout isn't available right now. Please try again later.")),
            ("invalid_request", screenLine),
            ("start_failed", screenLine),
            ("rate_limited", "\(screenLine)\n\(words)"),
            ("incorrect_cvc", String(localized: "Your card's security code (CVC) didn't match. Check the card details and try again.")),
        ]
        let client = FakeClient()
        var opened: [URL] = []
        let store = Self.store(client, opened: { opened.append($0); return true })
        var polled = 0
        for (code, purchaseError) in cases {
            client.hosted = .failure(StripeBillingError.refused(code: code, message: words))
            await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
            #expect(store.purchaseError == purchaseError, "\(code)")
            #expect(!store.isPurchasing, "\(code)")
            #expect(!store.purchaseSuccess, "\(code)")
            // only a refusal of the card offers Try again
            #expect(store.purchaseRetryPlan == (code == "incorrect_cvc" ? .yearly : nil), "\(code)")
        }
        #expect(opened.isEmpty)
        #expect(polled == 0)
        #expect(store.guestSignInRequiredSequence == 0)
    }

    /// The pay sheet's and the embedded session's refusals still fall through
    /// to the next stage: the sheet shows the hosted session's refusal, and a
    /// hosted page that opens still wins. A refusal of the card itself does
    /// not (aCardRefusalAtAnEarlierStageIsFinal).
    @Test @MainActor func theEarlierStagesRefusalsFallThroughToTheHostedSession() async {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.refused(code: "plan_unavailable", message: "No pay sheet price."))
        client.embedded = .failure(StripeBillingError.refused(code: "start_failed", message: "Stripe did not answer."))
        client.hosted = .failure(StripeBillingError.refused(code: "already_subscribed", message: "Already subscribed."))
        let store = Self.store(client)
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(client.calls == ["paymentSheet:monthly", "session:pro_monthly:embedded:never", "session:pro_monthly:hosted"])
        #expect(store.purchaseError == String(localized: "You already have Pro, so nothing was charged. Manage your subscription from your account."))

        // and a hosted page that opens still wins
        client.calls.removeAll()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_1"))
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(client.calls == ["paymentSheet:monthly", "session:pro_monthly:embedded:never", "session:pro_monthly:hosted"])
        #expect(store.purchaseError == nil)
        #expect(store.purchaseSuccess)
    }

    /// A refusal of the card itself (incorrect_cvc, a yearly trial's card that
    /// failed its CVC check) is final at whatever stage it comes: no later
    /// stage takes the card either. The plans come back with the refusal and
    /// Try again, which starts over with a new payment sheet.
    @Test @MainActor func aCardRefusalAtAnEarlierStageIsFinal() async {
        let cvcLine = String(localized: "Your card's security code (CVC) didn't match. Check the card details and try again.")

        // the pay sheet
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.refused(code: "incorrect_cvc", message: "Your card's security code (CVC) didn't match."))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret"))
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_1"))
        var opened: [URL] = []
        let store = Self.store(client, opened: { opened.append($0); return true })
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(client.calls == ["paymentSheet:yearly"])
        #expect(store.purchaseError == cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(store.checkout == nil)
        #expect(!store.isPurchasing)
        #expect(!store.purchaseSuccess)
        #expect(opened.isEmpty)
        #expect(polled == 0)

        // the embedded session
        client.calls.removeAll()
        client.paymentSheet = .failure(StripeBillingError.server("no sheet"))
        client.embedded = .failure(StripeBillingError.refused(code: "incorrect_cvc", message: ""))
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(client.calls == ["paymentSheet:yearly", "session:pro_yearly:embedded:never"])
        #expect(store.purchaseError == cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(opened.isEmpty)
        #expect(polled == 0)

        // Try again is a new purchase: a new payment sheet, and a clean attempt
        client.calls.removeAll()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_2", publishableKey: "pk"))
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(client.calls == ["paymentSheet:yearly"])
        #expect(store.checkout?.stage == .paySheet)
        #expect(store.purchaseError == nil)
        #expect(store.purchaseRetryPlan == nil)
    }

    // MARK: a guest network

    /// The server refuses every Stripe purchase of a legacy guest network with
    /// `guest_sign_in_required`. No later stage can sell it a plan, so the store
    /// stops there, shows no error and signals the add-sign-in sheet instead.
    @Test @MainActor func aGuestRefusalOfThePaySheetStopsWithoutAnError() async {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.guestSignInRequired)
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_test_secret"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(client.calls == ["paymentSheet:yearly"])
        #expect(store.guestSignInRequiredSequence == 1)
        #expect(store.purchaseError == nil)
        #expect(store.checkout == nil)
        #expect(!store.isPurchasing)
        #expect(!store.purchaseSuccess)
        #expect(polled == 0)
    }

    @Test @MainActor func aGuestRefusalOfACheckoutSessionStopsToo() async {
        // the embedded session
        let client = FakeClient()
        client.embedded = .failure(StripeBillingError.guestSignInRequired)
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_1"))
        var opened: [URL] = []
        let store = Self.store(client, opened: { opened.append($0); return true })
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(client.calls == ["paymentSheet:monthly", "session:pro_monthly:embedded:never"])
        #expect(opened.isEmpty)
        #expect(store.guestSignInRequiredSequence == 1)
        #expect(store.purchaseError == nil)
        #expect(!store.isPurchasing)

        // the hosted session, the last stage
        client.calls.removeAll()
        client.embedded = .failure(StripeBillingError.unavailable)
        client.hosted = .failure(StripeBillingError.guestSignInRequired)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(client.calls == ["paymentSheet:yearly", "session:pro_yearly:embedded:never", "session:pro_yearly:hosted"])
        #expect(store.guestSignInRequiredSequence == 2)
        #expect(store.purchaseError == nil)
        #expect(!store.isPurchasing)
    }

    @Test @MainActor func aBrowserThatWillNotOpenIsAFailure() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.stripe.com/c/pay/cs_1"))
        let store = Self.store(client, opened: { _ in false })
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.purchaseError != nil)
        #expect(!store.purchaseSuccess)
    }

    @Test @MainActor func aPageThatCannotLoadFallsThroughOncePerStage() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret"))
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.stripe.com/c/pay/cs_1"))
        var opened: [URL] = []
        let store = Self.store(client, opened: { opened.append($0); return true })
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.checkout?.stage == .paySheet)

        store.handleLoadFailed()
        await Self.settle()
        #expect(store.checkout?.stage == .embedded)

        store.handleLoadFailed()
        await Self.settle()
        #expect(store.checkout == nil)
        #expect(opened.count == 1)
        #expect(store.purchaseSuccess)
    }

    @Test @MainActor func aDeadWebProcessIsAFailure() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.handleProcessTerminated()
        #expect(store.checkout == nil)
        #expect(store.purchaseError == "Something went wrong. Please try again later.")
    }

    @Test @MainActor func aConfirmedReturnWithNothingInFlightOnlyStartsThePoll() async {
        let store = Self.store(FakeClient())
        #expect(store.handle(.payDone))
        #expect(!store.purchaseSuccess)
        #expect(!store.handle(.checkoutFailed(code: "-1", message: "x")))
        #expect(store.purchaseError == nil)
    }

    @Test @MainActor func aSecondPurchaseWhileOneIsOpenIsIgnored() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(client.calls == ["paymentSheet:yearly"])
    }

    @Test @MainActor func dismissingTheSheetResetsTheAttempt() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.resetPurchaseState()
        #expect(store.checkout == nil)
        #expect(!store.isPurchasing)
        #expect(!store.purchaseSuccess)
        #expect(store.purchaseError == nil)
    }

    @Test @MainActor func restoreReChecksThePlan() async {
        let store = Self.store(FakeClient())
        #expect(await store.restorePurchases() == .restored)
        #expect(store.restoreResultMessage == "Checking your plan again.")
        #expect(!store.isRestoringPurchases)
    }

    // MARK: the welcome offer (the onboarding plan step, the offer page and sheet)

    @Test @MainActor func theOfferIsRedeemableOnlyWhenThePricesSaySo() async {
        let client = FakeClient()
        let store = Self.store(client)
        // false until the prices arrive, so no offer surface shows early
        #expect(!store.offerEligible)
        await store.loadPrices(storefrontCountry: nil)
        #expect(!store.offerEligible)

        let eligible = Self.store(client)
        client.prices = .success(StripePlanPrices(yearlyUsd: 40, monthlyUsd: 5, currency: "usd", offerEligible: true))
        await eligible.loadPrices(storefrontCountry: nil)
        #expect(eligible.offerEligible)
    }

    @Test @MainActor func redeemingTheOfferBuysTheYearlyPlanThroughThePaySheet() async {
        // no code to enter: the server applies the welcome coupon to the
        // subscription the pay sheet starts
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_secret", publishableKey: "pk_1"))
        let store = Self.store(client)
        let offer = PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), appleOfferCode: "")
        var polled = 0
        await store.redeemOffer(offer, onSuccess: { polled += 1 })
        #expect(client.calls == ["paymentSheet:yearly"])
        #expect(store.checkout?.stage == .paySheet)
        #expect(store.checkout?.url.absoluteString.contains("plan=yearly") == true)

        // paid in the pay sheet: the same confirmation poll as a plain purchase
        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        #expect(polled == 1)
        #expect(store.purchaseSuccess)
    }

    @Test @MainActor func manageOpensTheCustomerPortal() async throws {
        let client = FakeClient()
        client.portal = .success(URL(string: "https://billing.stripe.com/p/session/x")!)
        let store = Self.store(client)
        let url = try await store.customerPortalURL()
        #expect(url.absoluteString == "https://billing.stripe.com/p/session/x")

        client.portal = .failure(StripeBillingError.server("no customer"))
        await #expect(throws: StripeBillingError.server("no customer")) {
            try await store.customerPortalURL()
        }
    }

    // MARK: reporting the payment

    /// A card payment credited Pro only when Stripe's webhook landed: the
    /// store dropped the id each stage started with and never told the
    /// server it had paid (support inbox 7247). Paid in the pay sheet, it
    /// reports the sheet's subscription before the poll starts.
    @Test @MainActor func thePaySheetsPaymentIsReportedByItsSubscription() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_secret", publishableKey: "pk_1", subscriptionId: "sub_test_1"))
        let store = Self.store(client)
        var reportsAtPoll: [StripePurchaseId] = []
        await store.purchase(plan: .yearly, onSuccess: { reportsAtPoll = client.reports })
        // nothing is paid yet
        #expect(client.reports.isEmpty)

        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        #expect(client.reports == [.subscription("sub_test_1")])
        #expect(reportsAtPoll == [.subscription("sub_test_1")])
    }

    @Test @MainActor func theEmbeddedCheckoutsPaymentIsReportedByItsSession() async {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.server("no sheet"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(client.reports.isEmpty)

        // a return that names no session reports the stage's own
        #expect(store.handle(.checkoutComplete(sessionId: nil)))
        #expect(client.reports == [.session("cs_test_1")])
    }

    @Test @MainActor func aReturnReportsTheSessionItNames() async {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.server("no sheet"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(store.handle(.checkoutComplete(sessionId: "cs_test_2")))
        #expect(client.reports == [.session("cs_test_2")])
    }

    /// A pay sheet that cannot load falls back to the embedded checkout, which
    /// is then what is paid: its session is reported, not the sheet's
    /// subscription.
    @Test @MainActor func aFallbackReportsTheStageThatWasPaid() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk", subscriptionId: "sub_test_1"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.handleLoadFailed()
        await Self.settle()
        #expect(store.checkout?.stage == .embedded)

        store.handle(.checkoutComplete(sessionId: nil))
        #expect(client.reports == [.session("cs_test_1")])
    }

    /// The browser's return may never reach the app, so the hosted page is
    /// reported as it opens; the sdk asks again while the checkout is open.
    /// Its return reports nothing more while that report runs.
    @Test @MainActor func theHostedPageIsReportedAsTheBrowserOpensIt() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(client.reports == [.session("cs_test_1")])
        #expect(polled == 1)

        #expect(store.handle(.checkoutComplete(sessionId: "cs_test_1")))
        #expect(client.reports == [.session("cs_test_1")])
        #expect(polled == 2)
    }

    /// A report the sdk gave up on (still pending after its attempts) frees
    /// the payment, so the browser's later return reports it again; one the
    /// server answered for good does not.
    @Test @MainActor func aReturnReportsAgainOnlyAfterAReportGaveUp() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        client.reportDones[0](StripePurchaseReport(status: SdkPurchaseReportStatusPending))
        await Self.settle()
        store.handle(.checkoutComplete(sessionId: "cs_test_1"))
        #expect(client.reports == [.session("cs_test_1"), .session("cs_test_1")])

        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_2", sessionId: "cs_test_2"))
        await store.purchase(plan: .yearly, onSuccess: {})
        client.reportDones[2](StripePurchaseReport(status: SdkPurchaseReportStatusCredited))
        await Self.settle()
        store.handle(.checkoutComplete(sessionId: "cs_test_2"))
        #expect(client.reports == [.session("cs_test_1"), .session("cs_test_1"), .session("cs_test_2")])
    }

    /// A return with no purchase open (a link from anywhere) reports nothing.
    @Test @MainActor func aReturnWithNothingOpenReportsNothing() async {
        let client = FakeClient()
        let store = Self.store(client)
        #expect(store.handle(.checkoutComplete(sessionId: "cs_test_1")))
        #expect(store.handle(.payDone))
        #expect(client.reports.isEmpty)
    }

    // MARK: a refused card payment

    private static let cvcLine = String(localized: "Your card's security code (CVC) didn't match. Check the card details and try again.")
    /// The server's answer for a yearly trial whose card failed its CVC check.
    private static let cvcRefusal = StripePurchaseReport(
        status: SdkPurchaseReportStatusInvalid,
        refusal: StripePurchaseRefusal(code: "incorrect_cvc", message: "Your card's security code (CVC) didn't match. Check the card details and try again.")
    )

    /// The client hands the store the sdk's answer: its status, and the
    /// refusal when the server named one (VerifyStorePurchaseResult.Error).
    @Test func theClientReadsTheRefusalOffTheSdksAnswer() {
        let refused = SdkVerifyStorePurchaseResult()
        refused.status = SdkPurchaseReportStatusInvalid
        let error = SdkOnboardingError()
        error.code = SdkPurchaseErrorCodeIncorrectCvc
        error.message = "Your card's security code (CVC) didn't match."
        refused.error = error
        #expect(SdkStripeBillingClient.report(refused, err: nil)
            == StripePurchaseReport(status: "invalid", refusal: StripePurchaseRefusal(code: "incorrect_cvc", message: "Your card's security code (CVC) didn't match.")))

        // an answer without one, and an older server's
        let credited = SdkVerifyStorePurchaseResult()
        credited.status = SdkPurchaseReportStatusCredited
        #expect(SdkStripeBillingClient.report(credited, err: nil) == StripePurchaseReport(status: "credited"))
        let invalid = SdkVerifyStorePurchaseResult()
        invalid.status = SdkPurchaseReportStatusInvalid
        #expect(SdkStripeBillingClient.report(invalid, err: nil)?.refusal == nil)

        // no answer
        #expect(SdkStripeBillingClient.report(nil, err: nil) == nil)
        #expect(SdkStripeBillingClient.report(refused, err: NSError(domain: "test", code: 1)) == nil)
    }

    /// The server refuses a yearly trial whose card failed its CVC check when
    /// the pay sheet's payment is reported (no Pro; the card is detached). The
    /// confirming screen gives way to the plans with the refusal and Try
    /// again, the poll is told to end, and a return for the same payment
    /// confirms nothing.
    @Test @MainActor func aRefusedPaySheetPaymentShowsInPlaceOfTheConfirmingScreen() async throws {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_secret", publishableKey: "pk_1", subscriptionId: "sub_test_1"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        #expect(store.purchaseSuccess)
        #expect(polled == 1)
        #expect(store.purchaseRefusal == nil)

        client.reportDones[0](Self.cvcRefusal)
        await Self.settle()
        #expect(!store.purchaseSuccess)
        #expect(!store.isPurchasing)
        #expect(store.checkout == nil)
        #expect(store.purchaseError == Self.cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(store.purchaseConfirmingTitle == nil)
        #expect(store.purchaseConfirmingMessage == nil)
        #expect(store.purchaseRefusal?.message == Self.cvcLine)

        // final: a stale return for the same payment confirms nothing and
        // reports nothing more
        #expect(!store.handle(.payDone))
        #expect(polled == 1)
        #expect(client.reports == [.subscription("sub_test_1")])
        #expect(!store.purchaseSuccess)

        // Try again is a new payment sheet, reported by its own subscription
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_2", publishableKey: "pk_1", subscriptionId: "sub_test_2"))
        await store.purchase(plan: try #require(store.purchaseRetryPlan), onSuccess: { polled += 1 })
        #expect(client.calls == ["paymentSheet:yearly", "paymentSheet:yearly"])
        #expect(store.purchaseError == nil)
        #expect(store.purchaseRetryPlan == nil)
        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        #expect(client.reports == [.subscription("sub_test_1"), .subscription("sub_test_2")])
        #expect(store.purchaseSuccess)
        #expect(polled == 2)
    }

    /// The embedded checkout's payment is refused the same way, by its session.
    @Test @MainActor func aRefusedEmbeddedCheckoutPaymentShowsInPlaceOfTheConfirmingScreen() async {
        let client = FakeClient()
        client.paymentSheet = .failure(StripeBillingError.server("no sheet"))
        client.embedded = .success(StripeCheckoutSessionResponse(clientSecret: "cs_secret", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.handle(.checkoutComplete(sessionId: nil)))
        #expect(client.reports == [.session("cs_test_1")])

        client.reportDones[0](Self.cvcRefusal)
        await Self.settle()
        #expect(!store.purchaseSuccess)
        #expect(store.purchaseError == Self.cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(store.purchaseRefusal?.message == Self.cvcLine)
        #expect(!store.handle(.checkoutComplete(sessionId: "cs_test_1")))
    }

    /// The hosted page is reported as the browser opens it, and the sdk asks
    /// again at 1 s, 5 s, 30 s and then every 5 minutes, so its refusal can
    /// come after the poll's two minutes ran out. It shows all the same, in
    /// place of "Finish in your browser."; and the browser handing the
    /// checkout back afterwards confirms nothing: no poll for a plan that is
    /// not coming.
    @Test @MainActor func theHostedPagesRefusalShowsLateAndItsReturnConfirmsNothing() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        var polled = 0
        await store.purchase(plan: .yearly, onSuccess: { polled += 1 })
        #expect(store.purchaseSuccess)
        #expect(store.purchaseConfirmingTitle == "Finish in your browser.")
        #expect(polled == 1)

        client.reportDones[0](StripePurchaseReport(
            status: SdkPurchaseReportStatusInvalid,
            refusal: StripePurchaseRefusal(code: "incorrect_cvc", message: "The server's own words.")
        ))
        await Self.settle()
        #expect(!store.purchaseSuccess)
        #expect(store.purchaseConfirmingTitle == nil)
        #expect(store.purchaseConfirmingMessage == nil)
        #expect(store.purchaseError == Self.cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(store.purchaseRefusal?.message == Self.cvcLine)

        #expect(!store.handle(.checkoutComplete(sessionId: "cs_test_1")))
        #expect(polled == 1)
        #expect(client.reports == [.session("cs_test_1")])
        #expect(store.purchaseError == Self.cvcLine)
        #expect(!store.purchaseSuccess)
    }

    /// The browser's return can come first, while the sdk waits to ask again:
    /// the confirming screen it brings gives way to the refusal just the same.
    @Test @MainActor func aRefusalAfterTheBrowsersReturnShowsInPlaceOfTheConfirmingScreen() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        #expect(store.handle(.checkoutComplete(sessionId: "cs_test_1")))
        #expect(store.purchaseConfirmingMessage == "We're confirming your purchase. Your plan will update automatically.")

        client.reportDones[0](Self.cvcRefusal)
        await Self.settle()
        #expect(!store.purchaseSuccess)
        #expect(store.purchaseConfirmingMessage == nil)
        #expect(store.purchaseError == Self.cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(store.purchaseRefusal?.message == Self.cvcLine)
    }

    /// The sheet was closed while the poll waited (the poll runs on): the
    /// refusal still ends the poll and says so on the app's overlay, and the
    /// next opening of the sheet shows it with Try again.
    @Test @MainActor func aRefusalAfterTheSheetClosedShowsTheNextTime() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.resetPurchaseState()
        #expect(!store.purchaseSuccess)

        client.reportDones[0](Self.cvcRefusal)
        await Self.settle()
        #expect(store.purchaseRefusal?.message == Self.cvcLine)
        #expect(store.purchaseError == Self.cvcLine)
        #expect(store.purchaseRetryPlan == .yearly)
        #expect(!store.purchaseSuccess)

        // closing the sheet again clears it
        store.resetPurchaseState()
        #expect(store.purchaseError == nil)
        #expect(store.purchaseRetryPlan == nil)
    }

    /// A purchase started since (a new pay sheet open) is not about the
    /// refused one: the poll is still told to end, but the open purchase
    /// keeps its state and the overlay says nothing it could read as its own.
    @Test @MainActor func aRefusalWhileAnotherPurchaseIsOpenLeavesItAlone() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.resetPurchaseState()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_2", publishableKey: "pk", subscriptionId: "sub_test_2"))
        await store.purchase(plan: .monthly, onSuccess: {})
        #expect(store.checkout?.stage == .paySheet)

        client.reportDones[0](Self.cvcRefusal)
        await Self.settle()
        #expect(store.checkout?.stage == .paySheet)
        #expect(store.isPurchasing)
        #expect(store.purchaseError == nil)
        #expect(store.purchaseRetryPlan == nil)
        #expect(store.purchaseRefusal != nil)
        #expect(store.purchaseRefusal?.message == nil)
    }

    /// A refusal of an earlier payment, when a later one went to the poll
    /// since, changes nothing: the later one's own report answers for it.
    @Test @MainActor func anEarlierPaymentsRefusalChangesNothing() async {
        let client = FakeClient()
        client.hosted = .success(StripeCheckoutSessionResponse(checkoutUrl: "https://checkout.example/c/pay/cs_test_1", sessionId: "cs_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .yearly, onSuccess: {})
        store.resetPurchaseState()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti_2", publishableKey: "pk", subscriptionId: "sub_test_2"))
        await store.purchase(plan: .monthly, onSuccess: {})
        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        #expect(store.purchaseSuccess)
        #expect(client.reports == [.session("cs_test_1"), .subscription("sub_test_2")])

        client.reportDones[0](Self.cvcRefusal)
        await Self.settle()
        #expect(store.purchaseSuccess)
        #expect(store.purchaseError == nil)
        #expect(store.purchaseRetryPlan == nil)
        #expect(store.purchaseRefusal == nil)
        // and its late return still confirms nothing
        #expect(!store.handle(.checkoutComplete(sessionId: "cs_test_1")))
    }

    /// Any answer that carries an error is a refusal. One with another code
    /// reads the sheet's own line with the server's words under it, as the
    /// Linux app reads it, and one without words the sheet's line alone;
    /// either offers Try again, since the server will take nothing more for
    /// that payment.
    @Test @MainActor func aRefusedReportWithAnotherCodeReadsTheSheetsLineWithTheServersWords() async {
        let client = FakeClient()
        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk", subscriptionId: "sub_test_1"))
        let store = Self.store(client)
        await store.purchase(plan: .monthly, onSuccess: {})
        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        client.reportDones[0](StripePurchaseReport(
            status: SdkPurchaseReportStatusInvalid,
            refusal: StripePurchaseRefusal(code: "card_declined", message: "Your card was declined.")
        ))
        await Self.settle()
        #expect(store.purchaseError == "Something went wrong. Please try again later.\nYour card was declined.")
        #expect(store.purchaseRetryPlan == .monthly)
        #expect(!store.purchaseSuccess)

        client.paymentSheet = .success(StripePaymentSheetResponse(setupIntentClientSecret: "seti", publishableKey: "pk", subscriptionId: "sub_test_2"))
        await store.purchase(plan: .monthly, onSuccess: {})
        store.handlePayMessage(["type": "ur-pay", "status": "succeeded"])
        client.reportDones[1](StripePurchaseReport(status: SdkPurchaseReportStatusInvalid, refusal: StripePurchaseRefusal(code: "", message: "")))
        await Self.settle()
        #expect(store.purchaseError == "Something went wrong. Please try again later.")
        #expect(store.purchaseRefusal?.sequence == 2)
    }

    /// Lets a fallback the store queued on the main actor run.
    @MainActor
    private static func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}
