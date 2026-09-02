//
//  ReferralTerms.swift
//  URnetwork
//
//  The referral program's numbers. The server's pro.yml is the single source
//  of truth and GET /account/referral-code carries them (max_referrals,
//  bonus_per_referral_bytes, referred_bonus_bytes, bonus_period_seconds), so
//  every app and the site print the same cap and bonus. The compile-time
//  defaults only cover the moment before the first fetch and a server that
//  reports no terms (no pro.yml).
//

import Foundation
import URnetworkSdk

struct ReferralTerms: Equatable {

    let maxReferrals: Int
    let bonusGiBPerDay: Int
    let referredBonusGiBPerDay: Int

    static let `default` = ReferralTerms(
        maxReferrals: referralMaxReferrals,
        bonusGiBPerDay: referralBonusGiBPerDay,
        referredBonusGiBPerDay: referralBonusGiBPerDay
    )

    /// How many of the network's referrals it is paid for.
    func paidReferrals(_ totalReferrals: Int) -> Int {
        if totalReferrals <= 0 {
            return 0
        }
        if maxReferrals > 0 && maxReferrals < totalReferrals {
            return maxReferrals
        }
        return totalReferrals
    }

    /// The GiB/day the network earns from its referrals.
    func earnedGiBPerDay(_ totalReferrals: Int) -> Int {
        paidReferrals(totalReferrals) * bonusGiBPerDay
    }

    /// The server's terms, keeping a default for any value the server left at zero.
    static func from(_ result: SdkGetNetworkReferralCodeResult) -> ReferralTerms {
        ReferralTerms(
            maxReferrals: positiveOr(Int64(result.maxReferrals), `default`.maxReferrals),
            bonusGiBPerDay: positiveOr(result.bonusGibPerDay(), `default`.bonusGiBPerDay),
            referredBonusGiBPerDay: positiveOr(result.referredBonusGibPerDay(), `default`.referredBonusGiBPerDay)
        )
    }

    private static func positiveOr(_ value: Int64, _ fallback: Int) -> Int {
        value > 0 ? Int(value) : fallback
    }
}
