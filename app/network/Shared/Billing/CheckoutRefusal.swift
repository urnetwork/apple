//
//  CheckoutRefusal.swift
//  URnetwork
//
//  What the direct-download build's purchase says when the server refuses
//  a Pro card purchase: a payment sheet or checkout session it will not
//  start (POST /subscription/stripe/payment-sheet,
//  /stripe/create-checkout-session), or a card payment it will not credit
//  after checkout (the payment report, POST
//  /subscription/verify-stripe-checkout). The server's code reads the way
//  ur.io's payment screens word the same refusals (mmm ur.io/react/src/lib/
//  paymentFailure.js), as the Android, Windows and Linux apps' own checkout
//  screens do:
//  - a code with a line of its own reads that translated line alone;
//  - invalid_request (a client defect) and start_failed (a start to try
//    again) read the screen's own line, with nothing under it;
//  - any other code, or none from an older server, reads the screen's own
//    line with the server's words under it.
//  A refused payment report (any answer that carries an error) reads the
//  card refusal's own line, and any other code the screen's own line with
//  the server's words under it, as the Linux app reads it (reportMessage).
//  Where StripeSubscriptionStore shows one: the hosted session's refusal,
//  the last stage's; the pay sheet's and the embedded session's fall
//  through to the next stage, except a refusal of the card itself
//  (incorrect_cvc, a yearly trial's card that failed its CVC check), which
//  is final at any stage and offers Try again (isCardRefusal).
//  guest_sign_in_required never gets here: it opens the add-sign-in sheet
//  (StripeBillingError.guestSignInRequired). A failure with no answer from
//  the server is not a refusal, and the screen keeps its own line for it.
//  Codes compare exactly, as the server sends them, like the guest code.
//

import Foundation
import URnetworkSdk

enum CheckoutRefusal {

    // the server's PurchaseErrorCode* values a Pro card purchase is refused
    // with, beside guest_sign_in_required
    private static let alreadySubscribed = "already_subscribed"
    private static let planUnavailable = "plan_unavailable"
    private static let checkoutUnavailable = "checkout_unavailable"
    private static let invalidRequest = "invalid_request"
    private static let startFailed = "start_failed"
    // a yearly trial's card that failed its CVC check: no Pro, and the card
    // was detached, so nothing is charged (the sdk names it)
    private static let incorrectCvc = SdkPurchaseErrorCodeIncorrectCvc

    /// Whether the server refused the card itself (incorrect_cvc). That is
    /// final for the purchase at whatever stage it comes, and the buyer checks
    /// the card and tries again, with a new payment sheet or checkout session.
    static func isCardRefusal(_ code: String) -> Bool {
        code == incorrectCvc
    }

    /// This app's own line for a refusal's code, nil for a code it has none for.
    static func line(code: String) -> String? {
        switch code {
        case alreadySubscribed:
            return String(localized: "You already have Pro, so nothing was charged. Manage your subscription from your account.")
        case planUnavailable:
            return String(localized: "This plan is not available right now. Try again later.")
        case checkoutUnavailable:
            // the checkout page's own checkout_unavailable reads the same (StripeCheckoutLinks)
            return String(localized: "Checkout isn't available right now. Please try again later.")
        case incorrectCvc:
            return String(localized: "Your card's security code (CVC) didn't match. Check the card details and try again.")
        default:
            return nil
        }
    }

    /// The error text for a refusal with the server's `code` and `words`.
    /// `screenLine` is the screen's own line; the words go under it only when
    /// they say something it does not, as on ur.io.
    static func message(code: String, words: String, screenLine: String) -> String {
        if let line = line(code: code) {
            return line
        }
        switch code {
        case invalidRequest, startFailed:
            return screenLine
        default:
            return lineWithWords(screenLine, words)
        }
    }

    /// The error text for a card payment the server refused after checkout
    /// (an answer to the payment report that carries an error): the card
    /// refusal's own line, and for any other code the screen's own line with
    /// the server's words under it, as the Linux app reads a refused report.
    static func reportMessage(code: String, words: String, screenLine: String) -> String {
        if isCardRefusal(code), let line = line(code: code) {
            return line
        }
        return lineWithWords(screenLine, words)
    }

    /// The screen's own line, with the server's words under it when they say
    /// something it does not, as on ur.io.
    private static func lineWithWords(_ screenLine: String, _ words: String) -> String {
        if words.isEmpty || words == screenLine {
            return screenLine
        }
        return "\(screenLine)\n\(words)"
    }
}
