//
//  StripeCheckoutLinks.swift
//  URnetwork
//
//  The ur.io pages the direct-download build's Stripe purchase runs through,
//  and the urnetwork:// URLs they hand control back with. Pure functions, so
//  the query encoding, the return parsing and the web view's navigation
//  decisions are unit tested. Mirrors linux/app/src/UpgradeSheet.cpp and
//  windows/app/src/App/BalanceSheets.cpp.
//
//  The pay page (mmm/ur.io /app/pay-sheet) mounts Stripe's Payment Element
//  for the payment sheet's client secret, confirms the intent, and hands
//  control back by navigating to the return url (success) or posting
//  {type: "ur-pay", status} to the `urpay` script message handler.
//
//  The bridge page (mmm/ur.io /checkout) mounts Stripe's Embedded Checkout
//  for the session's client_secret — the card form stays in Stripe's iframe,
//  no card data ever touches the app — and hands control back by navigating
//  to the redirect_link:
//    done:  urnetwork://checkout?status=complete&session_id=cs_...
//    error: urnetwork://checkout?errorCode=-1&errorMessage=...
//  The session is redirect_on_completion "never", and the url says so, so the
//  done hand-back comes from Stripe's onComplete on the page, in place, not
//  from a redirect through the server's return_url (the SDK's
//  BuildInlineCheckoutBridgeUrl builds the same url for windows and linux).
//

import Foundation
import URnetworkSdk

/// A urnetwork:// URL the Stripe purchase pages hand control back with.
enum BillingDeepLink: Equatable {
    /// The pay sheet confirmed the intent (`urnetwork://pay/done`).
    case payDone
    /// The pay sheet failed (`urnetwork://pay/error?errorMessage=`, synthesized from its message).
    case payError(message: String?)
    /// Embedded or hosted checkout completed (`urnetwork://checkout?status=complete&session_id=`).
    case checkoutComplete(sessionId: String?)
    /// Embedded checkout failed (`urnetwork://checkout?errorCode=&errorMessage=`).
    case checkoutFailed(code: String?, message: String?)

    init?(url: URL) {
        guard let link = StripeCheckoutLinks.parseReturn(url) else {
            return nil
        }
        self = link
    }

    /// The purchase went through on Stripe's side; the server learns of it by
    /// webhook, so the caller starts the confirmation poll.
    var isConfirmed: Bool {
        switch self {
        case .payDone, .checkoutComplete:
            return true
        case .payError, .checkoutFailed:
            return false
        }
    }

    /// The failure's message, when the page gave one.
    var errorMessage: String? {
        switch self {
        case .payDone, .checkoutComplete:
            return nil
        case .payError(let message):
            return message
        case .checkoutFailed(_, let message):
            return message
        }
    }
}

/// What the pay page said through the `urpay` message handler.
enum StripePaySheetOutcome: Equatable {
    case succeeded
    case cancelled
    case failed(message: String?)
}

/// What the web view does with a navigation the checkout page starts.
enum StripeCheckoutNavigation: Equatable {
    /// A urnetwork:// return: never a real navigation, the page is handing control back.
    case handBack(BillingDeepLink)
    /// A target=_blank link (Stripe's terms/privacy): the default browser.
    case openInBrowser
    /// Anything else loads in the web view.
    case load
}

enum StripeCheckoutLinks {

    static let paySheetPage = "https://ur.io/app/pay-sheet"
    static let checkoutPage = "https://ur.io/checkout"
    static let payReturn = "urnetwork://pay/done"
    static let checkoutRedirect = "urnetwork://checkout"
    static let returnScheme = "urnetwork"
    /// The script message handler the pay page posts to (`window.webkit.messageHandlers.urpay`).
    static let payMessageHandler = "urpay"
    static let payMessageType = "ur-pay"

    // MARK: URLs

    /// The inline pay sheet: `https://ur.io/app/pay-sheet?cs=&pk=&plan=&return=urnetwork://pay/done`.
    static func paySheetURL(clientSecret: String, publishableKey: String, plan: String) -> URL? {
        guard !clientSecret.isEmpty, !publishableKey.isEmpty else {
            return nil
        }
        let query = [
            ("cs", clientSecret),
            ("pk", publishableKey),
            ("plan", plan),
            ("return", payReturn),
        ]
        return URL(string: paySheetPage + "?" + encodeQuery(query))
    }

    /// The embedded checkout bridge for a redirect_on_completion "never" session:
    /// `https://ur.io/checkout?client_secret=&redirect_link=urnetwork://checkout&redirect_on_completion=never`.
    /// Without the flag the page would wait for a return_url redirect that a
    /// "never" session never makes.
    static func embeddedCheckoutURL(clientSecret: String) -> URL? {
        guard !clientSecret.isEmpty else {
            return nil
        }
        let query = [
            ("client_secret", clientSecret),
            ("redirect_link", checkoutRedirect),
            ("redirect_on_completion", SdkStripeRedirectOnCompletionNever),
        ]
        return URL(string: checkoutPage + "?" + encodeQuery(query))
    }

    /// Percent-encodes everything but the unreserved characters, like the
    /// desktop apps (g_uri_escape_string / WinRT Uri::EscapeComponent), so a
    /// secret or a scheme URL survives whatever the page's router does with it.
    static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    static func escape(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    // MARK: plans

    /// The checkout item a plan buys (StripeItemPro* on the server).
    static func itemId(for plan: PaymentOption) -> String {
        plan == .monthly ? SdkStripeItemProMonthly : SdkStripeItemProYearly
    }

    /// The plan as the pay sheet endpoint and the purchase events name it.
    static func planName(for plan: PaymentOption) -> String {
        plan == .monthly ? SdkPlanMonthly : SdkPlanYearly
    }

    /// The intent the pay sheet confirms: the SetupIntent for the yearly plan
    /// (the trial defers the charge), the PaymentIntent for monthly.
    static func intentClientSecret(setup: String, payment: String) -> String? {
        if !setup.isEmpty {
            return setup
        }
        if !payment.isEmpty {
            return payment
        }
        return nil
    }

    // MARK: returns

    /// The URL is one of ours (the `urnetwork` scheme), whatever it says.
    static func isReturnURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == returnScheme
    }

    /// The return a urnetwork:// URL carries, or nil when it is not a billing
    /// return (widget and onboarding links have their own parsers).
    static func parseReturn(_ url: URL) -> BillingDeepLink? {
        guard isReturnURL(url), let host = url.host?.lowercased() else {
            return nil
        }
        let params = queryParameters(url)
        switch host {
        case "pay":
            switch url.path {
            case "/done", "/done/":
                return .payDone
            case "/error", "/error/":
                return .payError(message: nonEmpty(params["errorMessage"]))
            default:
                return nil
            }
        case "checkout":
            if params["status"] == "complete" {
                return .checkoutComplete(sessionId: nonEmpty(params["session_id"]))
            }
            return .checkoutFailed(code: nonEmpty(params["errorCode"]), message: nonEmpty(params["errorMessage"]))
        default:
            return nil
        }
    }

    /// The query's parameters, percent-decoded, `+` read as a space (the
    /// bridge page builds the redirect with URLSearchParams).
    static func queryParameters(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return out
        }
        for item in items where out[item.name] == nil {
            out[item.name] = item.value?.replacingOccurrences(of: "+", with: " ") ?? ""
        }
        return out
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: the pay page's message

    /// The outcome a `{type: "ur-pay", status}` message carries. The body is the
    /// script message's body: the object itself, or its JSON text (the desktop
    /// bridges stringify it). Anything else, or another message type, is nil.
    static func paySheetOutcome(message body: Any) -> StripePaySheetOutcome? {
        var object: [String: Any]?
        if let dictionary = body as? [String: Any] {
            object = dictionary
        } else if let text = body as? String, let data = text.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        guard let object, object["type"] as? String == payMessageType else {
            return nil
        }
        let status = (object["status"] as? String ?? "").lowercased()
        switch status {
        case "succeeded", "complete", "processing", "ok":
            return .succeeded
        case "cancelled", "canceled":
            return .cancelled
        default:
            return .failed(message: nonEmpty(object["message"] as? String))
        }
    }

    // MARK: navigation

    /// What to do with a navigation the checkout page starts. `targetsNewWindow`
    /// is a navigation with no target frame (target=_blank / window.open).
    static func navigation(for url: URL, targetsNewWindow: Bool) -> StripeCheckoutNavigation {
        if isReturnURL(url) {
            // a return we cannot read still never loads: the scheme is ours
            return .handBack(parseReturn(url) ?? .checkoutFailed(code: nil, message: nil))
        }
        if targetsNewWindow {
            return .openInBrowser
        }
        return .load
    }
}
