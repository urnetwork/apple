import Foundation
import Testing
@testable import URnetwork

/// The ur.io pay/checkout URLs and their urnetwork:// returns (direct-download macOS build).
struct StripeCheckoutLinksTests {

    // MARK: URLs

    @Test func thePaySheetURLCarriesTheSecretTheKeyThePlanAndTheReturn() {
        let url = StripeCheckoutLinks.paySheetURL(clientSecret: "seti_1_secret_abc", publishableKey: "pk_test_9", plan: "yearly")
        #expect(url?.absoluteString
            == "https://ur.io/app/pay-sheet?cs=seti_1_secret_abc&pk=pk_test_9&plan=yearly&return=urnetwork%3A%2F%2Fpay%2Fdone")
    }

    @Test func theEmbeddedCheckoutURLCarriesTheSecretAndTheRedirect() {
        let url = StripeCheckoutLinks.embeddedCheckoutURL(clientSecret: "cs_test_a1_secret_z9")
        #expect(url?.absoluteString
            == "https://ur.io/checkout?client_secret=cs_test_a1_secret_z9&redirect_link=urnetwork%3A%2F%2Fcheckout")
    }

    @Test func queryValuesArePercentEncodedBeyondTheUnreservedSet() {
        #expect(StripeCheckoutLinks.escape("a b&c=d/e?f#g+h%i") == "a%20b%26c%3Dd%2Fe%3Ff%23g%2Bh%25i")
        #expect(StripeCheckoutLinks.escape("AZaz09-_.~") == "AZaz09-_.~")
        #expect(StripeCheckoutLinks.escape("é") == "%C3%A9")
        // an encoded secret round-trips through the page's URLSearchParams
        let url = StripeCheckoutLinks.paySheetURL(clientSecret: "s&x=1", publishableKey: "pk", plan: "monthly")!
        #expect(StripeCheckoutLinks.queryParameters(url) == ["cs": "s&x=1", "pk": "pk", "plan": "monthly", "return": "urnetwork://pay/done"])
    }

    @Test func aMissingSecretOrKeyBuildsNoURL() {
        #expect(StripeCheckoutLinks.paySheetURL(clientSecret: "", publishableKey: "pk", plan: "yearly") == nil)
        #expect(StripeCheckoutLinks.paySheetURL(clientSecret: "cs", publishableKey: "", plan: "yearly") == nil)
        #expect(StripeCheckoutLinks.embeddedCheckoutURL(clientSecret: "") == nil)
    }

    @Test func thePlanMapsToTheServersItemAndName() {
        #expect(StripeCheckoutLinks.itemId(for: .yearly) == "pro_yearly")
        #expect(StripeCheckoutLinks.itemId(for: .monthly) == "pro_monthly")
        #expect(StripeCheckoutLinks.planName(for: .yearly) == "yearly")
        #expect(StripeCheckoutLinks.planName(for: .monthly) == "monthly")
    }

    @Test func theSetupIntentWinsOverThePaymentIntent() {
        #expect(StripeCheckoutLinks.intentClientSecret(setup: "seti", payment: "pi") == "seti")
        #expect(StripeCheckoutLinks.intentClientSecret(setup: "", payment: "pi") == "pi")
        #expect(StripeCheckoutLinks.intentClientSecret(setup: "", payment: "") == nil)
    }

    // MARK: returns

    @Test func onlyTheURnetworkSchemeIsAReturn() {
        #expect(StripeCheckoutLinks.isReturnURL(URL(string: "urnetwork://pay/done")!))
        #expect(StripeCheckoutLinks.isReturnURL(URL(string: "URNETWORK://checkout?status=complete")!))
        #expect(!StripeCheckoutLinks.isReturnURL(URL(string: "https://ur.io/checkout?status=complete")!))
        #expect(!StripeCheckoutLinks.isReturnURL(URL(string: "urnetworkx://pay/done")!))
        #expect(!StripeCheckoutLinks.isReturnURL(URL(string: "javascript:alert(1)")!))
    }

    @Test func thePayReturnsParse() {
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://pay/done")!) == .payDone)
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://pay/done/")!) == .payDone)
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://pay/error?errorMessage=Card%20declined")!)
            == .payError(message: "Card declined"))
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://pay/error")!) == .payError(message: nil))
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://pay/elsewhere")!) == nil)
    }

    @Test func theCheckoutReturnsParse() {
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://checkout?status=complete&session_id=cs_test_1")!)
            == .checkoutComplete(sessionId: "cs_test_1"))
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://checkout?status=complete")!)
            == .checkoutComplete(sessionId: nil))
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://checkout?errorCode=-1&errorMessage=Your+card+was+declined.")!)
            == .checkoutFailed(code: "-1", message: "Your card was declined."))
        // status other than complete, or no status at all, is a failure (the page never leaves otherwise)
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://checkout?status=open")!)
            == .checkoutFailed(code: nil, message: nil))
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://checkout")!)
            == .checkoutFailed(code: nil, message: nil))
    }

    @Test func otherURnetworkLinksAreNotBillingReturns() {
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://widgets/connect")!) == nil)
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "urnetwork://onboarding/offer")!) == nil)
        #expect(StripeCheckoutLinks.parseReturn(URL(string: "https://ur.io/checkout?status=complete")!) == nil)
    }

    @Test func aReturnKnowsWhetherItConfirmed() {
        #expect(BillingDeepLink.payDone.isConfirmed)
        #expect(BillingDeepLink.checkoutComplete(sessionId: "cs").isConfirmed)
        #expect(!BillingDeepLink.payError(message: "x").isConfirmed)
        #expect(!BillingDeepLink.checkoutFailed(code: "-1", message: nil).isConfirmed)
        #expect(BillingDeepLink.checkoutFailed(code: "-1", message: "declined").errorMessage == "declined")
        #expect(BillingDeepLink.payDone.errorMessage == nil)
    }

    // MARK: the pay page's message

    @Test func thePayMessageReadsAsAnObjectOrAsJSONText() {
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "succeeded"]) == .succeeded)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: #"{"type":"ur-pay","status":"complete"}"#) == .succeeded)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "processing"]) == .succeeded)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "ok"]) == .succeeded)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "cancelled"]) == .cancelled)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "canceled"]) == .cancelled)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "failed", "message": "Card declined"])
            == .failed(message: "Card declined"))
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "ur-pay", "status": "error"]) == .failed(message: nil))
    }

    @Test func otherMessagesAreIgnored() {
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["type": "stripe", "status": "succeeded"]) == nil)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: ["status": "succeeded"]) == nil)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: "not json") == nil)
        #expect(StripeCheckoutLinks.paySheetOutcome(message: 42) == nil)
    }

    // MARK: navigation

    @Test func theWebViewHandsBackReturnsOpensNewWindowsInTheBrowserAndLoadsTheRest() {
        #expect(StripeCheckoutLinks.navigation(for: URL(string: "urnetwork://pay/done")!, targetsNewWindow: false)
            == .handBack(.payDone))
        // a return is never a real navigation, even when it targets a new window
        #expect(StripeCheckoutLinks.navigation(for: URL(string: "urnetwork://checkout?status=complete")!, targetsNewWindow: true)
            == .handBack(.checkoutComplete(sessionId: nil)))
        // an unreadable return still never loads
        #expect(StripeCheckoutLinks.navigation(for: URL(string: "urnetwork://pay/elsewhere")!, targetsNewWindow: false)
            == .handBack(.checkoutFailed(code: nil, message: nil)))
        #expect(StripeCheckoutLinks.navigation(for: URL(string: "https://stripe.com/legal")!, targetsNewWindow: true)
            == .openInBrowser)
        #expect(StripeCheckoutLinks.navigation(for: URL(string: "https://js.stripe.com/v3/")!, targetsNewWindow: false)
            == .load)
    }
}
