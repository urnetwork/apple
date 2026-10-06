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
        }
        #expect(opened.isEmpty)
        #expect(polled == 0)
        #expect(store.guestSignInRequiredSequence == 0)
    }

    /// The pay sheet's and the embedded session's refusals still fall through
    /// to the next stage: the sheet shows the hosted session's refusal, and a
    /// hosted page that opens still wins.
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

    /// Lets a fallback the store queued on the main actor run.
    @MainActor
    private static func settle() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}
