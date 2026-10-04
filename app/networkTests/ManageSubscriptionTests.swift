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

    @Test func nothingIsOfferedWithoutASubscriptionOrPro() {
        #expect(manageSubscriptionAction(platform: .iOS, hasAppStoreSubscription: false) == nil)
        #expect(manageSubscriptionAction(platform: .macOS, hasAppStoreSubscription: false) == nil)
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: false) == nil)
    }

    /// Inbox 561: a Pro plan billed by Stripe or Google Play cannot be managed
    /// through StoreKit, so the App Store builds open ur.io's Manage
    /// Subscription, signed in with a one-time code.
    @Test func aProPlanBilledElsewhereIsManagedOnTheWeb() {
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true) == .manageOnWeb)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true) == .manageOnWeb)
        // an App Store subscription is still managed through Apple
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true) == .storeKitSheet)
        #expect(
            manageSubscriptionAction(platform: .macOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true)
                == .openURL(appStoreSubscriptionsURL)
        )
    }

    @Test func theDirectDownloadBuildOpensTheStripePortalForAProNetwork() {
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true) == .stripePortal)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: false) == nil)
        // StoreKit is never consulted on the direct build
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: true, isPro: false) == nil)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: true, isPro: true) == .stripePortal)
    }

    @Test func theWebLinkOpensManageSubscriptionWithTheCode() throws {
        // the server's codes are base64url with "=" padding
        let url = try #require(manageSubscriptionOnWebURL(authCode: "AbC-dEf_123="))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "ur.io")
        #expect(components.path == "/app/subscription")
        #expect(components.queryItems == [URLQueryItem(name: "auth_code", value: "AbC-dEf_123=")])
        #expect(components.fragment == nil)
    }

    @Test func aCodeCannotChangeTheLink() throws {
        // "&", "#" and "+" stay inside the one parameter ("+" would read as a space)
        let url = try #require(manageSubscriptionOnWebURL(authCode: "a&next=x#y+z"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/app/subscription")
        #expect(components.queryItems == [URLQueryItem(name: "auth_code", value: "a&next=x#y+z")])
        #expect(components.fragment == nil)
        #expect(components.percentEncodedQuery?.contains("+") == false)
    }

    @Test func aBlankCodeGivesNoLink() {
        #expect(manageSubscriptionOnWebURL(authCode: "") == nil)
        #expect(manageSubscriptionOnWebURL(authCode: " \n") == nil)
    }

    @Test func theCurrentPlatformMatchesTheBuild() {
        #if os(macOS)
        #expect(ManageSubscriptionPlatform.current == .macOS)
        #else
        #expect(ManageSubscriptionPlatform.current == .iOS)
        #endif
    }

    @Test func theDefaultDistributionIsTheBuilds() {
        // without DIRECT_DOWNLOAD the App Store rules apply
        #expect(BillingDistribution.current == .appStore)
        #expect(manageSubscriptionAction(platform: .macOS, hasAppStoreSubscription: false, isPro: true) == .manageOnWeb)
    }
}
