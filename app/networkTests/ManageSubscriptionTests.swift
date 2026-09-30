import Foundation
import Testing
@testable import URnetwork

/// "Manage subscription" on the account screen (support inbox 561; Stripe portal for inbox 793).
struct ManageSubscriptionTests {

    @Test func iOSOpensTheStoreKitSheet() {
        #expect(manageSubscriptionAction(platform: .iOS, hasAppStoreSubscription: true) == .storeKitSheet)
    }

    @Test func macOSOpensTheAppStoreSubscriptionsPage() {
        #expect(
            manageSubscriptionAction(platform: .macOS, hasAppStoreSubscription: true)
                == .openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
        )
    }

    @Test func nothingIsOfferedWithoutAnAppStoreSubscription() {
        #expect(manageSubscriptionAction(platform: .iOS, hasAppStoreSubscription: false) == nil)
        #expect(manageSubscriptionAction(platform: .macOS, hasAppStoreSubscription: false) == nil)
        // a Pro plan from elsewhere is not an App Store subscription to manage
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true) == nil)
    }

    @Test func theDirectDownloadBuildOpensTheStripePortalForAProNetwork() {
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true) == .stripePortal)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: false) == nil)
        // StoreKit is never consulted on the direct build
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: true, isPro: false) == nil)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: true, isPro: true) == .stripePortal)
    }

    @Test func theCurrentPlatformMatchesTheBuild() {
        #if os(macOS)
        #expect(ManageSubscriptionPlatform.current == .macOS)
        #else
        #expect(ManageSubscriptionPlatform.current == .iOS)
        #endif
    }

    @Test func theDefaultDistributionIsTheBuilds() {
        // without DIRECT_DOWNLOAD the App Store rules apply, as they always have
        #expect(BillingDistribution.current == .appStore)
        #expect(manageSubscriptionAction(platform: .macOS, hasAppStoreSubscription: false, isPro: true) == nil)
    }
}
