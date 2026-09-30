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
}
