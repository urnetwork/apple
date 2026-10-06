//
//  CheckoutRefusal.swift
//  URnetwork
//
//  What the direct-download build's purchase says when the server refuses
//  to start a Pro checkout session (POST /stripe/create-checkout-session).
//  Only StripeSubscriptionStore's hosted stage shows one: it is the last
//  stage, and the pay sheet's and the embedded session's refusals fall
//  through to the next stage. The server's code reads the way ur.io's
//  payment screens word the same refusals (mmm ur.io/react/src/lib/
//  paymentFailure.js), as the Android, Windows and Linux apps' own checkout
//  screens do:
//  - a code with a line of its own reads that translated line alone;
//  - invalid_request (a client defect) and start_failed (a start to try
//    again) read the screen's own line, with nothing under it;
//  - any other code, or none from an older server, reads the screen's own
//    line with the server's words under it.
//  guest_sign_in_required never gets here: it opens the add-sign-in sheet
//  (StripeBillingError.guestSignInRequired). A failure with no answer from
//  the server is not a refusal, and the screen keeps its own line for it.
//  Codes compare exactly, as the server sends them, like the guest code.
//

import Foundation

enum CheckoutRefusal {

    // the server's PurchaseErrorCode* values a Pro checkout session is refused
    // with, beside guest_sign_in_required (the sdk names only that one)
    private static let alreadySubscribed = "already_subscribed"
    private static let planUnavailable = "plan_unavailable"
    private static let checkoutUnavailable = "checkout_unavailable"
    private static let invalidRequest = "invalid_request"
    private static let startFailed = "start_failed"

    /// The error text for a refusal with the server's `code` and `words`.
    /// `screenLine` is the screen's own line; the words go under it only when
    /// they say something it does not, as on ur.io.
    static func message(code: String, words: String, screenLine: String) -> String {
        switch code {
        case alreadySubscribed:
            return String(localized: "You already have Pro, so nothing was charged. Manage your subscription from your account.")
        case planUnavailable:
            return String(localized: "This plan is not available right now. Try again later.")
        case checkoutUnavailable:
            // the checkout page's own checkout_unavailable reads the same (StripeCheckoutLinks)
            return String(localized: "Checkout isn't available right now. Please try again later.")
        case invalidRequest, startFailed:
            return screenLine
        default:
            if words.isEmpty || words == screenLine {
                return screenLine
            }
            return "\(screenLine)\n\(words)"
        }
    }
}
