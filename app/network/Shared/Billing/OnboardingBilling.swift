//
//  OnboardingBilling.swift
//  URnetwork
//
//  The onboarding plan step's and the welcome-offer surfaces' decisions, pure
//  so they are tested: which purchase a tap on a plan starts, and whether a
//  welcome-offer surface (the onboarding offer page, the email link's offer
//  sheet) can be shown on this build. The App Store build redeems the offer
//  through the App Store offer code and can fall back to the plain yearly
//  trial; the direct-download build sells through Stripe, where the offer is
//  the server's welcome-offer coupon (GET /subscription/stripe/prices says
//  whether the caller may redeem it) and no trial is promised, so an offer
//  surface without a redeemable offer has nothing to show.
//

import Foundation

/// What a tap on a plan starts.
enum OnboardingPurchase: Equatable {
    /// The welcome offer on the yearly plan, through the store's offer path.
    case redeemOffer(PlanOffer)
    /// A plain purchase of the plan.
    case purchase(PaymentOption)

    /// The active welcome offer applies to the yearly plan only; the rest is a
    /// plain purchase.
    static func forSelection(_ plan: PaymentOption, offer: PlanOffer?) -> OnboardingPurchase {
        if plan == .yearly, let offer {
            return .redeemOffer(offer)
        }
        return .purchase(plan)
    }
}

enum WelcomeOfferSurface {

    /// Whether the onboarding flow has the offer page. On the App Store build
    /// that is everyone outside the in-app holdout: the page restates the
    /// offer issued on page 1 and falls back to the plain yearly trial when
    /// none could be issued. The direct-download build has no trial to fall
    /// back to, so the page needs the issued offer and the Stripe prices
    /// saying the coupon is redeemable.
    static func pageEnabled(
        distribution: BillingDistribution,
        offerScreenEnabled: Bool,
        offerIssued: Bool,
        stripeOfferEligible: Bool
    ) -> Bool {
        switch distribution {
        case .appStore:
            return offerScreenEnabled
        case .direct:
            return offerScreenEnabled && offerIssued && stripeOfferEligible
        }
    }

    /// Whether an onboarding email's offer link opens the offer on its own
    /// (otherwise the regular upgrade sheet): the issued offer, and on the
    /// direct-download build the Stripe prices saying it is redeemable.
    static func sheetEnabled(
        distribution: BillingDistribution,
        offerIssued: Bool,
        stripeOfferEligible: Bool
    ) -> Bool {
        switch distribution {
        case .appStore:
            return offerIssued
        case .direct:
            return offerIssued && stripeOfferEligible
        }
    }
}
