//
//  ManageSubscription.swift
//  URnetwork
//
//  Where "Manage subscription" goes. An App Store subscription can only be
//  changed or cancelled by Apple, so the app hands off to the system: the
//  StoreKit manage-subscriptions sheet on iOS, and the App Store account's
//  subscriptions page on macOS (the sheet is not available there). The entry
//  is offered only when this Apple ID holds an App Store subscription, whether
//  or not it is the one the signed-in network is using.
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
}

/// The App Store account's subscriptions page (Apple's own URL).
let appStoreSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

/// The manage-subscription action for this platform and distribution, or nil
/// when there is no subscription to manage: on the App Store builds, this
/// Apple ID's App Store subscription; on the direct-download build, the
/// network's Pro plan (Stripe, so StoreKit is never consulted).
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
        return nil
    }
    switch platform {
    case .iOS:
        return .storeKitSheet
    case .macOS:
        return .openURL(appStoreSubscriptionsURL)
    }
}
