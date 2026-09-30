import Foundation
import Testing
@testable import URnetwork

/// "Manage subscription" on the account screen (support inbox 561).
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
    }

    @Test func theCurrentPlatformMatchesTheBuild() {
        #if os(macOS)
        #expect(ManageSubscriptionPlatform.current == .macOS)
        #else
        #expect(ManageSubscriptionPlatform.current == .iOS)
        #endif
    }
}
