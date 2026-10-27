//
//  PaymentPastDue.swift
//  URnetwork
//
//  A renewal whose payment did not go through and which the store is still
//  retrying: the balance's payment_past_due (a declined card on a Stripe
//  renewal). Stripe retries for about two weeks and then cancels the
//  subscription, and an account with no email learns of it only in the app.
//  So the plan cards show the past-due notice exactly while the latest balance
//  carries it, with "Update payment method", which opens ur.io's Manage
//  Subscription signed in with a one-time auth code. There is no time rule and
//  no state of its own: a balance without it (no failing renewal, or an older
//  server) hides the notice.
//
//  Every build shows it. The App Store builds already send a Pro plan billed
//  outside the App Store to ur.io's Manage Subscription (support inbox 561),
//  and the direct-download build bills through Stripe.
//
//  The wire's update_payment_url is not kept: the link is always
//  manageSubscriptionOnWebBaseURL, so a sign-in code is never attached to a
//  server-supplied URL.
//

import Foundation
import URnetworkSdk

/// The balance's payment_past_due, without its update_payment_url.
struct PaymentPastDue: Equatable {
    /// The store retrying the renewal: "stripe".
    var store: String
    /// When the renewal first failed, RFC 3339.
    var failTime: String
}

extension PaymentPastDue {

    /// The SDK's value; nil when the balance has none.
    init?(_ pastDue: SdkPaymentPastDue?) {
        guard let pastDue else {
            return nil
        }
        self.init(store: pastDue.store, failTime: pastDue.failTime)
    }

    /// "Update payment method"'s link: ur.io's Manage Subscription signed in
    /// with a one-time auth code, or without a code when none could be made
    /// (the web then asks the user to sign in).
    static func updatePaymentMethodURL(createAuthCode: () async throws -> String) async -> URL {
        if let authCode = try? await createAuthCode(), let url = manageSubscriptionOnWebURL(authCode: authCode) {
            return url
        }
        return manageSubscriptionOnWebBaseURL
    }
}
