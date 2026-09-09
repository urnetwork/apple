//
//  PlanPresentation.swift
//  URnetwork
//
//  What every plan surface shows, computed once from the server's price tier,
//  the welcome offer when one is active, and the StoreKit products when they
//  have loaded. The presentation is a pure value so the strings can be tested
//  without the store: the yearly plan leads with the amount billed, a
//  subordinate per-month equivalent (ceiling-rounded, never on the regional
//  tier), the saving against twelve monthly payments, and the trial; the
//  monthly plan says it is billed monthly; the offer replaces the yearly
//  headline with the first-year amount and adds the renewal line.
//

import Foundation

/// A price the store answered with, or a list price standing in for it.
struct PlanPrice: Equatable {
    var amount: Decimal
    /// The ISO 4217 code the amount is in.
    var currencyCode: String = "USD"
    /// How this price formats an amount in its currency ("$29.99").
    var format: (Decimal) -> String

    var display: String { format(amount) }

    static func == (lhs: PlanPrice, rhs: PlanPrice) -> Bool {
        lhs.amount == rhs.amount && lhs.display == rhs.display
    }

    /// A USD list price shown at the store's price point: whole dollars land one
    /// cent under ($40 → $39.99, $0.50 → $0.49), which is what the storefront charges.
    static func usdListPrice(_ usd: Double) -> PlanPrice {
        let point = Self.storePoint(usd)
        return PlanPrice(amount: point, format: Self.formatUsd)
    }

    static func storePoint(_ usd: Double) -> Decimal {
        let cents = Int((usd * 100).rounded())
        let pointCents = cents % 100 == 0 || cents % 10 == 0 ? cents - 1 : cents
        return Decimal(max(pointCents, 1)) / 100
    }

    static func formatUsd(_ amount: Decimal) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        return String(format: "$%.2f", value)
    }
}

/// The server's price tier as the presentation needs it.
struct PlanTier: Equatable {
    var name: String
    var yearlyUsd: Double
    var monthlyUsd: Double
    var isRegional: Bool

    static let standard = PlanTier(name: "standard", yearlyUsd: 40, monthlyUsd: 5, isRegional: false)
}

/// The welcome offer as the presentation needs it (only while active).
struct PlanOffer: Equatable {
    var percentOff: Int
    var monthsFree: Int
    var expiresAt: Date
    var appleOfferCode: String
}

/// The per-month equivalent of the yearly price, as the SDK computes it.
struct PlanEquivalent: Equatable {
    var monthlyEquivalent: Decimal
    var showEquivalent: Bool
    var savingPercent: Int
}

struct PlanPresentation: Equatable {

    var yearly: PlanPrice
    var monthly: PlanPrice
    var trialDays: Int
    var tier: PlanTier
    var offer: PlanOffer?
    var equivalent: PlanEquivalent?
    /// The storefront country's name for the regional tier's billing line, when known.
    var storefrontCountryName: String?

    /// The presentation for a surface: list prices from the tier until the store
    /// answers; each loaded product refines its own row.
    static func resolve(
        tier: PlanTier?,
        offer: PlanOffer?,
        storeMonthly: PlanPrice?,
        storeYearly: PlanPrice?,
        trialDays: Int,
        equivalent: PlanEquivalent?,
        storefrontCountryName: String? = nil
    ) -> PlanPresentation {
        let tier = tier ?? .standard
        return PlanPresentation(
            yearly: storeYearly ?? .usdListPrice(tier.yearlyUsd),
            monthly: storeMonthly ?? .usdListPrice(tier.monthlyUsd),
            trialDays: trialDays,
            tier: tier,
            offer: offer,
            equivalent: equivalent,
            storefrontCountryName: storefrontCountryName
        )
    }

    var hasOffer: Bool { offer != nil }

    /// The offer's first-year amount in the yearly price's currency, at the store point.
    var firstYearPrice: PlanPrice? {
        guard let offer else { return nil }
        let discounted = yearly.amount * Decimal(100 - offer.percentOff) / 100
        var rounded = Decimal()
        var source = discounted
        NSDecimalRound(&rounded, &source, 2, .down)
        return PlanPrice(amount: rounded, currencyCode: yearly.currencyCode, format: yearly.format)
    }

    // MARK: yearly card

    /// "$39.99/year", or with the offer "$29.99 for your first year".
    var yearlyTitle: String {
        if let firstYearPrice {
            return String(format: String(localized: "%@ for your first year"), firstYearPrice.display)
        }
        return String(format: String(localized: "%@/year"), yearly.display)
    }

    /// The lines under the yearly title, in order.
    var yearlyLines: [String] {
        var lines: [String] = []
        if hasOffer {
            lines.append(String(format: String(localized: "then %@/year"), yearly.display))
        } else if let equivalent, equivalent.showEquivalent, !tier.isRegional {
            lines.append(String(
                format: String(localized: "≈ %@/month · billed once a year"),
                yearly.format(equivalent.monthlyEquivalent)
            ))
        } else if tier.isRegional, let storefrontCountryName {
            lines.append(String(format: String(localized: "Billed once a year · price for %@"), storefrontCountryName))
        }
        lines.append(String(format: String(localized: "Includes %lld day free trial"), trialDays))
        return lines
    }

    /// The pill on the yearly card: the saving when there is one, else "Best value".
    var yearlyPill: String {
        if let equivalent, equivalent.savingPercent > 0 {
            return String(format: String(localized: "Save %lld%%"), equivalent.savingPercent)
        }
        return String(localized: "Best value")
    }

    // MARK: monthly card

    var monthlyTitle: String {
        String(format: String(localized: "%@/month"), monthly.display)
    }

    var monthlyLines: [String] {
        [String(localized: "Billed monthly · cancel anytime")]
    }

    // MARK: button and terms

    func ctaTitle(for option: PaymentOption) -> String {
        switch option {
        case .monthly:
            return String(localized: "Subscribe")
        case .yearly:
            if let offer {
                return String(format: String(localized: "Start free trial with %lld months free"), offer.monthsFree)
            }
            return String(localized: "Start free trial")
        }
    }

    /// The terms line under the button for the yearly plan; nil for monthly, whose card says it all.
    func termsLine(for option: PaymentOption) -> String? {
        guard option == .yearly else { return nil }
        if let firstYearPrice {
            return String(
                format: String(localized: "%lld days free, then %@ for your first year, then %@/year. Cancel anytime."),
                trialDays, firstYearPrice.display, yearly.display
            )
        }
        return String(format: String(localized: "%lld days free, then %@/year. Cancel anytime."), trialDays, yearly.display)
    }

    /// "Available until Friday, 12 September 2026 at 09:14" in the user's locale.
    func availableUntilLine(now: Date = Date()) -> String? {
        guard let offer else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return String(format: String(localized: "Available until %@"), formatter.string(from: offer.expiresAt))
    }
}
