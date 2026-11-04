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
    /// neither of them the tunnel's own process, and its purchase leaves the
    /// connection as it is (purchaseDropsConnection). The App Store builds do not
    /// need it: on iOS the purchase runs in system daemons outside the tunnel, and
    /// the Mac App Store client, which does honor the tunnel, gets a flow that
    /// disconnects around the store itself (the A6 note on
    /// AppStoreSubscriptionManager.purchase).
    var checkoutRidesTunnel: Bool { self == .direct }

    /// Whether a purchase drops the connection for the store, after a notice
    /// (ConnectViewModel.purchaseAroundConnection): only the Mac App Store build's,
    /// whose store client honors the tunnel's default route (the A6 note on
    /// AppStoreSubscriptionManager.purchase).
    ///
    /// The direct download keeps the connection. Its page loads after the purchase
    /// call has returned, so a disconnect around that call was over before the page
    /// asked for anything, and the page went through the tunnel all the same: the
    /// drop gained nothing, left the traffic unprotected for a moment, and its
    /// notice's Cancel stopped the purchase. A tunnel holding the traffic is what
    /// stands in that page's way, and its out-of-balance alert says so
    /// (checkoutRidesTunnel). iOS purchases run outside the tunnel.
    var purchaseDropsConnection: Bool {
        #if os(macOS)
        return self == .appStore
        #else
        return false
        #endif
    }
}
