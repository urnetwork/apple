//
//  ReferralBonusLineTests.swift
//  networkTests
//
//  The usage bar's referral row printed the raw referral count, which
//  ReferralLinkViewModel starts at 0 and keeps at 0 when the read fails, so
//  a new user saw "Total referrals: 0" and "+0 GiB/Day" until the read
//  landed, and for good when it failed. The row now waits for the read, and
//  its bonus follows the server's terms.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct ReferralBonusLineTests {

    private struct FetchError: Error {}

    private static func result(code: String, total: Int, bonusPerReferralBytes: Int64 = 0) -> SdkGetNetworkReferralCodeResult {
        let result = SdkGetNetworkReferralCodeResult()
        result.referralCode = code
        result.totalReferrals = total
        if bonusPerReferralBytes > 0 {
            result.bonusPerReferralBytes = bonusPerReferralBytes
            result.bonusPeriodSeconds = 24 * 60 * 60
        }
        return result
    }

    @Test func theBonusWaitsForTheReferralRead() {
        let viewModel = ReferralLinkViewModel(fetchReferralCode: { throw FetchError() })

        #expect(viewModel.referralBonusLine == .loading)
    }

    @Test func aFailedReferralReadIsNotAZeroBonus() async {
        let viewModel = ReferralLinkViewModel(fetchReferralCode: { throw FetchError() })

        await viewModel.fetchReferralLink()

        #expect(viewModel.referralBonusLine == .unavailable)
    }

    @Test func aLandedReadShowsTheEarnedBonusAndAFailedPollKeepsIt() async {
        var attempts = 0
        let viewModel = ReferralLinkViewModel(fetchReferralCode: {
            attempts += 1
            if attempts == 2 {
                throw FetchError()
            }
            return Self.result(code: "TESTBONUS1", total: 2)
        })

        await viewModel.fetchReferralLink()
        #expect(viewModel.referralBonusLine == .earned(totalReferrals: 2, gibPerDay: 6))

        await viewModel.fetchReferralLink()
        #expect(viewModel.referralBonusLine == .earned(totalReferrals: 2, gibPerDay: 6))

        UserDefaults.standard.removeObject(forKey: "referral.celebratedCount.TESTBONUS1")
    }

    @Test func theBonusFollowsTheServersTerms() async {
        let gib: Int64 = 1024 * 1024 * 1024
        let viewModel = ReferralLinkViewModel(fetchReferralCode: {
            Self.result(code: "TESTBONUS2", total: 2, bonusPerReferralBytes: 5 * gib)
        })

        await viewModel.fetchReferralLink()
        #expect(viewModel.referralBonusLine == .earned(totalReferrals: 2, gibPerDay: 10))

        UserDefaults.standard.removeObject(forKey: "referral.celebratedCount.TESTBONUS2")
    }
}
