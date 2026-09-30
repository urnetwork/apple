import Foundation
import Testing
@testable import URnetwork

/// The urnetwork:// returns NetworkApp.onOpenURL routes to the Stripe store (direct-download build).
struct BillingDeepLinkTests {

    @Test func thePayAndCheckoutReturnsRoute() {
        #expect(BillingDeepLink(url: URL(string: "urnetwork://pay/done")!) == .payDone)
        #expect(BillingDeepLink(url: URL(string: "urnetwork://checkout?status=complete&session_id=cs_1")!)
            == .checkoutComplete(sessionId: "cs_1"))
        #expect(BillingDeepLink(url: URL(string: "urnetwork://checkout?errorCode=-1&errorMessage=No")!)
            == .checkoutFailed(code: "-1", message: "No"))
    }

    @Test func otherLinksDoNot() {
        // the widget, onboarding and Google sign-in URLs keep their own handlers
        #expect(BillingDeepLink(url: URL(string: "urnetwork://widgets/connect")!) == nil)
        #expect(BillingDeepLink(url: URL(string: "urnetwork://onboarding/connect")!) == nil)
        #expect(BillingDeepLink(url: URL(string: "urnetwork://pay")!) == nil)
        #expect(BillingDeepLink(url: URL(string: "com.googleusercontent.apps.x:/oauth2redirect")!) == nil)
        #expect(BillingDeepLink(url: URL(string: "https://ur.io/checkout?status=complete")!) == nil)
    }

    @Test @MainActor func theRouterHoldsTheReturnUntilItIsTaken() {
        let router = DeepLinkRouter()
        #expect(router.consumeBilling() == nil)
        router.open(BillingDeepLink.payDone)
        #expect(router.pendingBilling == .payDone)
        #expect(router.consumeBilling() == .payDone)
        #expect(router.pendingBilling == nil)
        #expect(router.consumeBilling() == nil)
    }
}
