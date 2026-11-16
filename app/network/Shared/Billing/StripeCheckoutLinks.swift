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
//    error: urnetwork://checkout?errorCode=<code>&errorMessage=...
//  The error's code is one of the SDK's CheckoutBridgeError* (-1 from pages
//  before the codes): the app shows its own words for a code it knows and
//  the page's English text for any other.
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

    /// The purchase went through on Stripe's side: the store reports it to
    /// the server, and the caller starts the confirmation poll.
    var isConfirmed: Bool {
        switch self {
        case .payDone, .checkoutComplete:
            return true
        case .payError, .checkoutFailed:
            return false
        }
    }

    /// The failure's message, when the page gave one: for embedded checkout,
    /// this app's words for a code it knows, else the page's own text.
    var errorMessage: String? {
        switch self {
        case .payDone, .checkoutComplete:
            return nil
        case .payError(let message):
            return message
        case .checkoutFailed(let code, let message):
            return StripeCheckoutLinks.checkoutErrorText(code: code) ?? message
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
    /// Anything else loads in the web view (a new window a 3D Secure
    /// challenge asks for goes on to the window it opens, newWindow).
    case load
}

/// Where a new window the checkout page asks for opens.
enum StripeCheckoutNewWindow: Equatable {
    /// A small window in the app: one that Stripe's frames, or the bank page
    /// Stripe's challenge frame shows, open by script or post a form to, as a
    /// 3D Secure challenge can. In the default browser it could not answer
    /// the page that opened it, and a posted form would arrive empty.
    case challengeWindow
    /// The default browser: a link (Stripe's terms and privacy), or a window
    /// the checkout page itself opens.
    case browser
    /// Nothing opens: a urnetwork:// return, or a URL no browser takes.
    case nothing
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

    /// This app's words for the checkout page's code for a failure (SDK
    /// CheckoutBridgeError*), nil for any other: the page's invalid_request
    /// and checkout_error, whose text says what, and the -1 of pages before
    /// the codes.
    static func checkoutErrorText(code: String?) -> String? {
        guard let code else {
            return nil
        }
        switch code {
        case SdkCheckoutBridgeErrorUnavailable:
            return String(localized: "Checkout isn't available right now. Please try again later.")
        case SdkCheckoutBridgeErrorStripeUnavailable:
            return String(localized: "The payment form couldn't load. Check your internet connection, then try again.")
        default:
            return nil
        }
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
    /// is a navigation with no target frame (target=_blank / window.open);
    /// `linkActivated` and `fromSubframe` say who asked (newWindow).
    static func navigation(for url: URL, targetsNewWindow: Bool, linkActivated: Bool = true, fromSubframe: Bool = false) -> StripeCheckoutNavigation {
        if isReturnURL(url) {
            // a return we cannot read still never loads: the scheme is ours
            return .handBack(parseReturn(url) ?? .checkoutFailed(code: nil, message: nil))
        }
        if targetsNewWindow {
            // a challenge's window goes on to the web view's window request
            // (a form posted to a new window asks here first), which opens it
            if newWindow(for: url, linkActivated: linkActivated, fromSubframe: fromSubframe) == .challengeWindow {
                return .load
            }
            return .openInBrowser
        }
        return .load
    }

    // MARK: new windows

    /// Where a new window opens. `linkActivated` is a click on a link
    /// (target=_blank), as opposed to a script (window.open) or a form posted
    /// to a new window. `fromSubframe` is a request from a frame inside the
    /// checkout page: on the pay page and the checkout bridge those are only
    /// Stripe's frames (the card form, its 3D Secure challenge) and the bank
    /// pages the challenge frame shows, so no other site gets a window in the
    /// app. A link still opens in the browser, and so does anything the page
    /// itself opens.
    static func newWindow(for url: URL?, linkActivated: Bool, fromSubframe: Bool) -> StripeCheckoutNewWindow {
        if let url, isReturnURL(url) {
            return .nothing
        }
        if fromSubframe && !linkActivated && challengeWindowOpens(url) {
            return .challengeWindow
        }
        guard let scheme = url?.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) else {
            return .nothing
        }
        return .browser
    }

    /// What a challenge window may open on: an https page, or the blank page
    /// a script opens before it navigates or posts a form to it.
    static func challengeWindowOpens(_ url: URL?) -> Bool {
        guard let url, !url.absoluteString.isEmpty else {
            // window.open() with no URL: about:blank
            return true
        }
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "about":
            return url.absoluteString.lowercased() == "about:blank"
        default:
            return false
        }
    }

    /// What loads inside a challenge window: https pages, and blank or srcdoc
    /// frames. Nothing else does: no urnetwork:// return (the checkout page
    /// hands back, not its challenge), no plain http, and no other scheme, so
    /// a page there cannot launch an app.
    static func challengeWindowLoads(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "about":
            return ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased())
        default:
            return false
        }
    }
}
