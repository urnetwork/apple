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
/// portal (StoreKit is never consulted), except a one-time crypto year
/// (`storeClass` "crypto", ClassifySubscriptionStore), which never renews and
/// has nothing to manage. Nothing to manage on the network for a redeemed
/// gift year either (`storeClass` "gift", which planStore gives only while no
/// other store bills the network): the plan row says it doesn't renew
/// instead (giftPlanLine). An App Store subscription this Apple ID holds is
/// still Apple's to manage, next to a gift as next to any plan.
func manageSubscriptionAction(
    platform: ManageSubscriptionPlatform,
    distribution: BillingDistribution = .current,
    hasAppStoreSubscription: Bool,
    isPro: Bool = false,
    storeClass: String = ""
) -> ManageSubscriptionAction? {
    if distribution == .direct {
        return isPro && !subscriptionStoreIsCrypto(storeClass) && !subscriptionStoreIsGift(storeClass) ? .stripePortal : nil
    }
    guard hasAppStoreSubscription else {
        return isPro && !subscriptionStoreIsGift(storeClass) ? .manageOnWeb : nil
    }
    switch platform {
    case .iOS:
        return .storeKitSheet
    case .macOS:
        return .openURL(appStoreSubscriptionsURL)
    }
}

/// Whether the current subscription is a redeemed gift code's year of Pro
/// (the SDK's ClassifySubscriptionStore family "gift", the store "gift"):
/// someone else paid for it and it never renews, so there is nothing to
/// manage or cancel (mmm/GIFTOFPRIVACY.md 10.5, "After redemption,
/// everywhere").
func subscriptionStoreIsGift(_ storeClass: String) -> Bool {
    storeClass == "gift"
}

/// The store the plan row describes (Android's planStore): the current
/// subscription's, except a gift while another store also bills the network.
/// A gift year starts after any paid period, and a store subscription that
/// renews after that overlaps it and keeps charging (a redeem bills no one).
/// The server names one active store as current, which can be the gift, so
/// then the first store of `activeStores` (the balance's `subscriptions`:
/// every store billing the network now) that is not a gift is described, and
/// its manage action stays.
func planStore(currentStore: String, activeStores: [String]) -> String {
    guard subscriptionStoreIsGift(CryptoPaymentSdk.storeClass(currentStore)) else {
        return currentStore
    }
    return activeStores.first { store in
        !store.isEmpty && !subscriptionStoreIsGift(CryptoPaymentSdk.storeClass(store))
    } ?? currentStore
}

/// The plan row's line where "Manage subscription" would be, for a redeemed
/// gift year of Pro: the gift's twin of a one-time crypto year's
/// does-not-renew line. nil for every other plan.
func giftPlanLine(isPro: Bool, storeClass: String) -> String? {
    guard isPro, subscriptionStoreIsGift(storeClass) else {
        return nil
    }
    return String(localized: "A gift. It doesn't renew.")
}
