import Foundation
import Testing
import URnetworkSdk
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

    /// The plan row's store family for a balance: its current store and
    /// every store billing it now (the balance's `subscriptions`).
    private func planStoreClass(current: String, active: [String]) -> String {
        CryptoPaymentSdk.storeClass(planStore(currentStore: current, activeStores: active))
    }

    /// A redeemed gift year alone (the store "gift", mmm/GIFTOFPRIVACY.md
    /// 10.5): someone else paid and it never renews, so no build offers to
    /// manage or cancel it on the network, and the plan row says so instead.
    @Test func aGiftAloneShowsTheGiftLine() {
        let storeClass = planStoreClass(current: "gift", active: ["gift"])
        #expect(storeClass == "gift")
        // an older server sends no `subscriptions`
        #expect(planStoreClass(current: "gift", active: []) == "gift")

        for platform in [ManageSubscriptionPlatform.iOS, .macOS] {
            for distribution in [BillingDistribution.appStore, .direct] {
                #expect(
                    manageSubscriptionAction(
                        platform: platform,
                        distribution: distribution,
                        hasAppStoreSubscription: false,
                        isPro: true,
                        storeClass: storeClass
                    ) == nil,
                    "\(platform) \(distribution)"
                )
            }
        }
        #expect(giftPlanLine(isPro: true, storeClass: storeClass) == String(localized: "A gift. It doesn't renew."))
    }

    /// A paying subscriber who redeems a gift keeps the manage action of the
    /// store still billing, to cancel instead of paying during the gift year,
    /// though the server named the gift as current; the gift line doesn't
    /// replace it.
    @Test func anAppStoreSubscriptionPlusAGiftKeepsManage() {
        let storeClass = planStoreClass(current: "gift", active: ["gift", "apple"])
        #expect(storeClass == "apple")
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true, storeClass: storeClass) == .storeKitSheet)
        #expect(
            manageSubscriptionAction(platform: .macOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true, storeClass: storeClass)
                == .openURL(appStoreSubscriptionsURL)
        )
        // bought with another Apple ID: still billing, managed on the web
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true, storeClass: storeClass) == .manageOnWeb)
        #expect(giftPlanLine(isPro: true, storeClass: storeClass) == nil)
    }

    @Test func aCardOrPlaySubscriptionPlusAGiftKeepsManage() {
        let stripe = planStoreClass(current: "gift", active: ["gift", "stripe"])
        #expect(stripe == "stripe")
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true, storeClass: stripe) == .manageOnWeb)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true, storeClass: stripe) == .stripePortal)
        #expect(giftPlanLine(isPro: true, storeClass: stripe) == nil)

        let play = planStoreClass(current: "gift", active: ["google", "gift"])
        #expect(play == "google")
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true, storeClass: play) == .manageOnWeb)
        #expect(giftPlanLine(isPro: true, storeClass: play) == nil)
    }

    /// An App Store subscription this Apple ID holds is Apple's to manage
    /// next to a gift, as next to any plan, even one the network's balance
    /// doesn't list (another network's, or one the server hasn't seen yet).
    @Test func thisAppleIdsAppStoreSubscriptionStaysManagedBesideAGift() {
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true, storeClass: "gift") == .storeKitSheet)
        #expect(
            manageSubscriptionAction(platform: .macOS, distribution: .appStore, hasAppStoreSubscription: true, isPro: true, storeClass: "gift")
                == .openURL(appStoreSubscriptionsURL)
        )
        // StoreKit is never consulted on the direct build
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: true, isPro: true, storeClass: "gift") == nil)
    }

    /// Only a gift gives way: a current store that isn't a gift is described
    /// as it was.
    @Test func thePlanStoreIsTheCurrentStoreUnlessItIsAGift() {
        #expect(planStore(currentStore: "stripe", activeStores: ["gift", "stripe"]) == "stripe")
        #expect(planStore(currentStore: "apple", activeStores: ["apple"]) == "apple")
        #expect(planStore(currentStore: "monero", activeStores: ["gift", "monero"]) == "monero")
        #expect(planStore(currentStore: "", activeStores: []) == "")
        // the first store still billing that is not a gift
        #expect(planStore(currentStore: "gift", activeStores: ["", "gift", "stripe", "apple"]) == "stripe")
    }

    /// The plan row says the gift doesn't renew where Manage subscription
    /// would be, and only for a gift.
    @Test func theGiftLineTakesManageSubscriptionsPlace() {
        #expect(giftPlanLine(isPro: true, storeClass: "gift") == String(localized: "A gift. It doesn't renew."))
        for storeClass in ["apple", "google", "stripe", "crypto", "other", ""] {
            #expect(giftPlanLine(isPro: true, storeClass: storeClass) == nil, "\(storeClass)")
        }
        #expect(giftPlanLine(isPro: false, storeClass: "gift") == nil)
        // every other Pro plan keeps its manage control
        #expect(manageSubscriptionAction(platform: .iOS, distribution: .appStore, hasAppStoreSubscription: false, isPro: true, storeClass: "stripe") == .manageOnWeb)
        #expect(manageSubscriptionAction(platform: .macOS, distribution: .direct, hasAppStoreSubscription: false, isPro: true, storeClass: "stripe") == .stripePortal)
    }

    @Test func theGiftStoreIsTheSdksGiftFamily() {
        #expect(subscriptionStoreIsGift(SdkSubscriptionStoreGift))
        #expect(subscriptionStoreIsGift(CryptoPaymentSdk.storeClass("gift")))
        #expect(subscriptionStoreIsGift(CryptoPaymentSdk.storeClass("GIFT")))
        // only the store "gift": a store id that merely contains it keeps its family
        #expect(CryptoPaymentSdk.storeClass("stripe_gift") == SdkSubscriptionStoreStripe)
        #expect(!subscriptionStoreIsGift("crypto"))
        #expect(!subscriptionStoreIsGift(""))
    }

    @Test func theDefaultDistributionIsTheBuilds() {
        // without DIRECT_DOWNLOAD the App Store rules apply
        #expect(BillingDistribution.current == .appStore)
        #expect(manageSubscriptionAction(platform: .macOS, hasAppStoreSubscription: false, isPro: true) == .manageOnWeb)
    }
}
