//
//  BillingDistribution.swift
//  URnetwork
//
//  Which billing the build ships with. The Mac App Store build sells Pro
//  through StoreKit; the direct-download DMG (Developer ID, system extension)
//  cannot use StoreKit and bills through Stripe like Windows and Linux. This
//  is the ONE place that reads the DIRECT_DOWNLOAD compile flag: everything
//  else branches on `BillingDistribution.current`, so the App Store build
//  compiles and behaves exactly as before when the flag is absent.
//

import Foundation

enum BillingDistribution: Equatable {
    /// Mac App Store / iOS App Store: StoreKit billing.
    case appStore
    /// The direct-download macOS build: Stripe billing, no StoreKit.
    case direct

    static let current: BillingDistribution = {
        #if DIRECT_DOWNLOAD
        return .direct
        #else
        return .appStore
        #endif
    }()

    /// Whether a purchase has to go through this device's tunnel, so that a tunnel
    /// holding traffic stops it until the user disconnects. There is no way around
    /// that on purpose: a checkout bypass could leak. The out-of-balance alert says
    /// so where it is true (OutOfBalanceNotice.disconnectFirst).
    ///
    /// The direct download pays on a page: the sheet's WKWebView or the browser,
    /// neither of them the tunnel's own process, and the macOS purchase flow's
    /// reconnect comes as soon as the page is asked for, before it has loaded. The
    /// App Store builds do not need it: on iOS the purchase runs in system daemons
    /// outside the tunnel, and the Mac App Store client, which does honor the tunnel,
    /// gets a flow that disconnects around the store itself (the A6 note on
    /// AppStoreSubscriptionManager.purchase).
    var checkoutRidesTunnel: Bool { self == .direct }
}
