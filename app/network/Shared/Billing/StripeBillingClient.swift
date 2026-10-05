//
//  StripeBillingClient.swift
//  URnetwork
//
//  The four server calls the Stripe purchase and manage flows make, as
//  async functions over the SDK's gomobile callbacks, behind a protocol so
//  StripeSubscriptionStore's flow is unit tested with a fake.
//

import Foundation
import URnetworkSdk

struct StripePaymentSheetResponse: Equatable {
    var setupIntentClientSecret: String = ""
    var paymentIntentClientSecret: String = ""
    var publishableKey: String = ""
    var trialDays: Int = 0
    var errorMessage: String? = nil
}

struct StripeCheckoutSessionResponse: Equatable {
    var clientSecret: String = ""
    var checkoutUrl: String = ""
    var errorMessage: String? = nil
}

enum StripeBillingError: LocalizedError, Equatable {
    /// The server answered with an error message.
    case server(String)
    /// The server refused the purchase because the network is a legacy guest
    /// with no sign-in method (`guest_sign_in_required`): it adds one first
    /// (GuestPurchaseGate), and no other checkout can sell it a plan.
    case guestSignInRequired
    /// No usable answer (transport failure, or a session without the shape asked for).
    case unavailable

    var errorDescription: String? {
        switch self {
        case .server(let message):
            return message
        case .guestSignInRequired, .unavailable:
            return String(localized: "Something went wrong. Please try again later.")
        }
    }

    /// The error a refused payment sheet or checkout session throws: the
    /// server's code when the app acts on it, else its message.
    static func refused(code: String, message: String) -> StripeBillingError {
        code == SdkPurchaseErrorCodeGuestSignInRequired ? .guestSignInRequired : .server(message)
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
            trialDays: result.trialDays
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
        return StripeCheckoutSessionResponse(clientSecret: result.clientSecret, checkoutUrl: result.checkoutUrl)
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
