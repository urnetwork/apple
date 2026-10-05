//
//  ManageSubscription.swift
//  URnetwork
//
//  Where "Manage subscription" goes. An App Store subscription can only be
//  changed or cancelled by Apple, so the app hands off to the system: the
//  StoreKit manage-subscriptions sheet on iOS, and the App Store account's
//  subscriptions page on macOS (the sheet is not available there). That is
//  offered whenever this Apple ID holds an App Store subscription, whether or
//  not it is the one the signed-in network is using.
//
//  A Pro plan billed elsewhere (Stripe on the web, Google Play) cannot be
//  managed through StoreKit, so the App Store builds open ur.io's Manage
//  Subscription in the browser, signed in with a one-time auth code
//  (support inbox 561). ur.io removes the code from the address bar on
//  arrival and asks before it switches a browser signed in to another network.
//

import Foundation

enum ManageSubscriptionPlatform: Equatable {
    case iOS
    case macOS

    static var current: ManageSubscriptionPlatform {
        #if os(macOS)
        return .macOS
        #else
        return .iOS
        #endif
    }
}

enum ManageSubscriptionAction: Equatable {
    /// StoreKit's manage-subscriptions sheet, in the app.
    case storeKitSheet
    /// Open the App Store's subscriptions page.
    case openURL(URL)
    /// The Stripe customer portal (POST /stripe/customer-portal), opened in
    /// the browser: the direct-download build's plans are billed by Stripe.
    case stripePortal
    /// ur.io's Manage Subscription in the browser, signed in with a one-time
    /// auth code (see manageSubscriptionOnWebURL): a Pro plan this Apple ID
    /// does not bill.
    case manageOnWeb
}

/// The App Store account's subscriptions page (Apple's own URL).
let appStoreSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

/// ur.io's Manage Subscription, which manages every billing store (Stripe,
/// Google Play, the App Store) for the signed-in network.
let manageSubscriptionOnWebBaseURL = URL(string: "https://ur.io/app/subscription")!

/// The Manage Subscription link carrying a one-time auth code (POST
/// /auth/code-create), or nil for a blank code. The code is percent-encoded
/// as one query value, so no character in it can add a parameter or a
/// fragment ("+" included, which the web would read as a space).
func manageSubscriptionOnWebURL(authCode: String) -> URL? {
    let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else {
        return nil
    }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+#?")
    guard
        let encoded = code.addingPercentEncoding(withAllowedCharacters: allowed),
        var components = URLComponents(url: manageSubscriptionOnWebBaseURL, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    components.percentEncodedQuery = "auth_code=\(encoded)"
    return components.url
}

/// The manage-subscription action for this platform and distribution, or nil
/// when there is nothing to manage. On the App Store builds: this Apple ID's
/// App Store subscription through Apple, else a Pro plan billed elsewhere on
/// ur.io. On the direct-download build: the network's Pro plan in the Stripe
/// portal (StoreKit is never consulted).
func manageSubscriptionAction(
    platform: ManageSubscriptionPlatform,
    distribution: BillingDistribution = .current,
    hasAppStoreSubscription: Bool,
    isPro: Bool = false
) -> ManageSubscriptionAction? {
    if distribution == .direct {
        return isPro ? .stripePortal : nil
    }
    guard hasAppStoreSubscription else {
        return isPro ? .manageOnWeb : nil
    }
    switch platform {
    case .iOS:
        return .storeKitSheet
    case .macOS:
        return .openURL(appStoreSubscriptionsURL)
    }
}
