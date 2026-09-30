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
}

/// The App Store account's subscriptions page (Apple's own URL).
let appStoreSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

/// The manage-subscription action for this platform, or nil when there is no
/// App Store subscription to manage.
func manageSubscriptionAction(
    platform: ManageSubscriptionPlatform,
    hasAppStoreSubscription: Bool
) -> ManageSubscriptionAction? {
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
