import Foundation
import Testing
@testable import URnetwork

/// The onboarding plan step's and the welcome-offer surfaces' decisions:
/// which purchase a plan tap starts, and when an offer surface is shown on
/// each build (StoreKit on the App Store, Stripe on the direct download).
struct OnboardingBillingTests {

    private static let offer = PlanOffer(percentOff: 25, monthsFree: 3, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), appleOfferCode: "WELCOME")

    // MARK: plan selection

    @Test func theWelcomeOfferAppliesToTheYearlyPlan() {
        #expect(OnboardingPurchase.forSelection(.yearly, offer: Self.offer) == .redeemOffer(Self.offer))
    }

    @Test func theMonthlyPlanIsAPlainPurchaseEvenWithAnOffer() {
        #expect(OnboardingPurchase.forSelection(.monthly, offer: Self.offer) == .purchase(.monthly))
    }

    @Test func withoutAnOfferEveryPlanIsAPlainPurchase() {
        #expect(OnboardingPurchase.forSelection(.yearly, offer: nil) == .purchase(.yearly))
        #expect(OnboardingPurchase.forSelection(.monthly, offer: nil) == .purchase(.monthly))
    }

    // MARK: the onboarding offer page

    @Test func theAppStoreOfferPageFollowsTheHoldoutOnly() {
        // the page falls back to the plain yearly trial when no offer was issued
        #expect(WelcomeOfferSurface.pageEnabled(distribution: .appStore, offerScreenEnabled: true, offerIssued: false, stripeOfferEligible: false))
        #expect(WelcomeOfferSurface.pageEnabled(distribution: .appStore, offerScreenEnabled: true, offerIssued: true, stripeOfferEligible: false))
        #expect(!WelcomeOfferSurface.pageEnabled(distribution: .appStore, offerScreenEnabled: false, offerIssued: true, stripeOfferEligible: true))
    }

    @Test func theDirectDownloadOfferPageNeedsARedeemableStripeOffer() {
        #expect(WelcomeOfferSurface.pageEnabled(distribution: .direct, offerScreenEnabled: true, offerIssued: true, stripeOfferEligible: true))
        // no trial to fall back to: no issued offer, no page
        #expect(!WelcomeOfferSurface.pageEnabled(distribution: .direct, offerScreenEnabled: true, offerIssued: false, stripeOfferEligible: true))
        // the prices have not said the coupon is redeemable (or have not arrived)
        #expect(!WelcomeOfferSurface.pageEnabled(distribution: .direct, offerScreenEnabled: true, offerIssued: true, stripeOfferEligible: false))
        // the holdout still applies
        #expect(!WelcomeOfferSurface.pageEnabled(distribution: .direct, offerScreenEnabled: false, offerIssued: true, stripeOfferEligible: true))
    }

    // MARK: the email link's offer sheet

    @Test func theAppStoreOfferSheetNeedsTheIssuedOffer() {
        #expect(WelcomeOfferSurface.sheetEnabled(distribution: .appStore, offerIssued: true, stripeOfferEligible: false))
        #expect(!WelcomeOfferSurface.sheetEnabled(distribution: .appStore, offerIssued: false, stripeOfferEligible: true))
    }

    @Test func theDirectDownloadOfferSheetNeedsTheIssuedOfferAndTheStripeCoupon() {
        #expect(WelcomeOfferSurface.sheetEnabled(distribution: .direct, offerIssued: true, stripeOfferEligible: true))
        #expect(!WelcomeOfferSurface.sheetEnabled(distribution: .direct, offerIssued: true, stripeOfferEligible: false))
        #expect(!WelcomeOfferSurface.sheetEnabled(distribution: .direct, offerIssued: false, stripeOfferEligible: true))
    }
}
