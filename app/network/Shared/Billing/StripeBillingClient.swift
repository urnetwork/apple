//
//  StripeBillingClient.swift
//  URnetwork
//
//  The server calls the Stripe purchase and manage flows make, over the
//  SDK's gomobile callbacks, behind a protocol so StripeSubscriptionStore's
//  flow is unit tested with a fake.
//

import Foundation
import URnetworkSdk

struct StripePaymentSheetResponse: Equatable {
    var setupIntentClientSecret: String = ""
    var paymentIntentClientSecret: String = ""
    var publishableKey: String = ""
    var trialDays: Int = 0
    /// The subscription the sheet pays (sub_...), which reports the payment.
    var subscriptionId: String = ""
    var errorMessage: String? = nil
}

struct StripeCheckoutSessionResponse: Equatable {
    var clientSecret: String = ""
    var checkoutUrl: String = ""
    /// The checkout session (cs_...), which reports the payment.
    var sessionId: String = ""
    var errorMessage: String? = nil
}

/// The id a card purchase started with, which reports it once paid
/// (Api.ReportStripePurchase takes exactly one).
enum StripePurchaseId: Hashable {
    /// A checkout session (cs_...), embedded or hosted.
    case session(String)
    /// The pay sheet's subscription (sub_...).
    case subscription(String)
}

enum StripeBillingError: LocalizedError, Equatable {
    /// The server answered with an error message.
    case server(String)
    /// The server refused a payment sheet or checkout session: its code (one
    /// of the server's PurchaseErrorCode* values, empty from an older server)
    /// and its English message. The purchase words it with CheckoutRefusal.
    case refusal(code: String, message: String)
    /// The server refused the purchase because the network is a legacy guest
    /// with no sign-in method (`guest_sign_in_required`): it adds one first
    /// (GuestPurchaseGate), and no other checkout can sell it a plan.
    case guestSignInRequired
    /// No usable answer (transport failure, or a session without the shape asked for).
    case unavailable

    var errorDescription: String? {
        switch self {
        case .server(let message), .refusal(_, let message):
            return message
        case .guestSignInRequired, .unavailable:
            return String(localized: "Something went wrong. Please try again later.")
        }
    }

    /// The error a refused payment sheet or checkout session throws: the
    /// guest refusal the app acts on, else the server's code and message.
    static func refused(code: String, message: String) -> StripeBillingError {
        code == SdkPurchaseErrorCodeGuestSignInRequired ? .guestSignInRequired : .refusal(code: code, message: message)
    }
}

protocol StripeBillingClient {
    func prices(storefrontCountry: String?) async throws -> StripePlanPrices
    func paymentSheet(plan: String, storefrontCountry: String?) async throws -> StripePaymentSheetResponse
    /// `redirectOnCompletion` is "never" (SdkStripeRedirectOnCompletionNever) for
    /// an embedded session that hands back from Stripe's onComplete, empty to
    /// leave it unset.
    func checkoutSession(itemId: String, uiMode: String, redirectOnCompletion: String, storefrontCountry: String?) async throws -> StripeCheckoutSessionResponse
    func customerPortalURL() async throws -> URL
    /// Tells the server a card payment finished, so it credits the plan
    /// without waiting for Stripe's webhook. Returns at once: the sdk asks
    /// again while the server answers pending (about 21 minutes), then calls
    /// `done` once, on any thread, with the last status
    /// (SdkPurchaseReportStatus*), nil when no attempt was answered.
    func reportStripePurchase(_ purchaseId: StripePurchaseId, done: @escaping (String?) -> Void)
}

/// The client over the SDK api. A nil api (no network space yet) fails every call.
final class SdkStripeBillingClient: StripeBillingClient {

    private let api: SdkApi?

    init(api: SdkApi?) {
        self.api = api
    }

    func prices(storefrontCountry: String?) async throws -> StripePlanPrices {
        guard let api else { throw StripeBillingError.unavailable }
        let result: SdkStripePricesResult = try await withCheckedThrowingContinuation { continuation in
            api.stripePrices(storefrontCountry ?? "", callback: StripePricesCallback { result, err in
                if let result, err == nil {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: StripeBillingError.unavailable)
                }
            })
        }
        if let error = result.error {
            throw StripeBillingError.server(error.message)
        }
        return StripePlanPrices(result)
    }

    func paymentSheet(plan: String, storefrontCountry: String?) async throws -> StripePaymentSheetResponse {
        guard let api else { throw StripeBillingError.unavailable }
        let args = SdkStripePaymentSheetArgs()
        args.plan = plan
        args.storefrontCountry = storefrontCountry ?? ""
        let result: SdkStripePaymentSheetResult = try await withCheckedThrowingContinuation { continuation in
            api.stripePaymentSheet(args, callback: StripePaymentSheetCallback { result, err in
                if let result, err == nil {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: StripeBillingError.unavailable)
                }
            })
        }
        if let error = result.error {
            throw StripeBillingError.refused(code: error.code, message: error.message)
        }
        return StripePaymentSheetResponse(
            setupIntentClientSecret: result.setupIntentClientSecret,
            paymentIntentClientSecret: result.paymentIntentClientSecret,
            publishableKey: result.publishableKey,
            trialDays: result.trialDays,
            subscriptionId: result.subscriptionId
        )
    }

    func checkoutSession(itemId: String, uiMode: String, redirectOnCompletion: String, storefrontCountry: String?) async throws -> StripeCheckoutSessionResponse {
        guard let api else { throw StripeBillingError.unavailable }
        let args = SdkStripeCreateCheckoutSessionArgs()
        args.itemId = itemId
        args.uiMode = uiMode
        args.redirectOnCompletion = redirectOnCompletion
        args.storefrontCountry = storefrontCountry ?? ""
        let result: SdkStripeCreateCheckoutSessionResult = try await withCheckedThrowingContinuation { continuation in
            api.createStripeCheckoutSession(args, callback: StripeCheckoutSessionCallback { result, err in
                if let result, err == nil {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: StripeBillingError.unavailable)
                }
            })
        }
        if let error = result.error {
            throw StripeBillingError.refused(code: error.code, message: error.message)
        }
        return StripeCheckoutSessionResponse(clientSecret: result.clientSecret, checkoutUrl: result.checkoutUrl, sessionId: result.sessionId)
    }

    func customerPortalURL() async throws -> URL {
        guard let api else { throw StripeBillingError.unavailable }
        let result: SdkStripeCreateCustomerPortalResult = try await withCheckedThrowingContinuation { continuation in
            api.stripeCreateCustomerPortal(SdkStripeCreateCustomerPortalArgs(), callback: StripeCustomerPortalCallback { result, err in
                if let result, err == nil {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: StripeBillingError.unavailable)
                }
            })
        }
        if let error = result.error {
            throw StripeBillingError.server(error.message)
        }
        guard let url = URL(string: result.url), !result.url.isEmpty else {
            throw StripeBillingError.unavailable
        }
        return url
    }

    func reportStripePurchase(_ purchaseId: StripePurchaseId, done: @escaping (String?) -> Void) {
        guard let api else {
            done(nil)
            return
        }
        let args = SdkVerifyStripeCheckoutArgs()
        switch purchaseId {
        case .session(let sessionId):
            args.sessionId = sessionId
        case .subscription(let subscriptionId):
            args.subscriptionId = subscriptionId
        }
        api.reportStripePurchase(args, callback: StripePurchaseReportCallback { result, err in
            done(err == nil ? result?.status : nil)
        })
    }
}

// MARK: gomobile callbacks

private final class StripePricesCallback: NSObject, SdkStripePricesCallbackProtocol {
    let handler: (SdkStripePricesResult?, Error?) -> Void
    init(_ handler: @escaping (SdkStripePricesResult?, Error?) -> Void) { self.handler = handler }
    func result(_ result: SdkStripePricesResult?, err: Error?) { handler(result, err) }
}

private final class StripePaymentSheetCallback: NSObject, SdkStripePaymentSheetCallbackProtocol {
    let handler: (SdkStripePaymentSheetResult?, Error?) -> Void
    init(_ handler: @escaping (SdkStripePaymentSheetResult?, Error?) -> Void) { self.handler = handler }
    func result(_ result: SdkStripePaymentSheetResult?, err: Error?) { handler(result, err) }
}

private final class StripeCheckoutSessionCallback: NSObject, SdkStripeCreateCheckoutSessionCallbackProtocol {
    let handler: (SdkStripeCreateCheckoutSessionResult?, Error?) -> Void
    init(_ handler: @escaping (SdkStripeCreateCheckoutSessionResult?, Error?) -> Void) { self.handler = handler }
    func result(_ result: SdkStripeCreateCheckoutSessionResult?, err: Error?) { handler(result, err) }
}

private final class StripeCustomerPortalCallback: NSObject, SdkStripeCreateCustomerPortalCallbackProtocol {
    let handler: (SdkStripeCreateCustomerPortalResult?, Error?) -> Void
    init(_ handler: @escaping (SdkStripeCreateCustomerPortalResult?, Error?) -> Void) { self.handler = handler }
    func result(_ result: SdkStripeCreateCustomerPortalResult?, err: Error?) { handler(result, err) }
}

private final class StripePurchaseReportCallback: NSObject, SdkVerifyStripeCheckoutCallbackProtocol {
    let handler: (SdkVerifyStorePurchaseResult?, Error?) -> Void
    init(_ handler: @escaping (SdkVerifyStorePurchaseResult?, Error?) -> Void) { self.handler = handler }
    func result(_ result: SdkVerifyStorePurchaseResult?, err: Error?) { handler(result, err) }
}
