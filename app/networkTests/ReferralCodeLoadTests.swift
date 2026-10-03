//
//  ReferralCodeLoadTests.swift
//  networkTests
//
//  A failed referral code fetch left the code nil, and the referral panel
//  showed a spinner for an empty code with no error and no retry, so the user
//  watched a spinner that never ended. The fetch now records the failure, the
//  panel shows an error with a retry, and a later success clears it.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct ReferralCodeLoadTests {

    private struct FetchError: Error {}

    private static func result(code: String, total: Int) -> SdkGetNetworkReferralCodeResult {
        let result = SdkGetNetworkReferralCodeResult()
        result.referralCode = code
        result.totalReferrals = total
        return result
    }

    @Test func aFailedFetchIsReportedNotLeftLoading() async {
        let viewModel = ReferralLinkViewModel(fetchReferralCode: { throw FetchError() })

        await viewModel.fetchReferralLink()

        #expect(viewModel.referralCode == nil)
        #expect(viewModel.loadFailed)
        #expect(!viewModel.isLoading)
        #expect(ReferralCodeSlot.of(referralCode: viewModel.referralCode ?? "", loadFailed: viewModel.loadFailed) == .failed)
    }

    @Test func aRetryThatSucceedsClearsTheFailure() async {
        var attempts = 0
        let viewModel = ReferralLinkViewModel(fetchReferralCode: {
            attempts += 1
            if attempts == 1 {
                throw FetchError()
            }
            return Self.result(code: "TESTCODE", total: 0)
        })

        await viewModel.fetchReferralLink()
        #expect(viewModel.loadFailed)

        await viewModel.fetchReferralLink()
        #expect(!viewModel.loadFailed)
        #expect(viewModel.referralCode == "TESTCODE")
        #expect(ReferralCodeSlot.of(referralCode: viewModel.referralCode ?? "", loadFailed: viewModel.loadFailed) == .code("TESTCODE"))

        // the success recorded a celebration baseline for this code
        UserDefaults.standard.removeObject(forKey: "referral.celebratedCount.TESTCODE")
    }

    @Test func aKnownCodeStaysShownWhenARefreshFails() {
        // the 60 s poll can fail after the code arrived; keep showing the code
        #expect(ReferralCodeSlot.of(referralCode: "TESTCODE", loadFailed: true) == .code("TESTCODE"))
    }

    @Test func noCodeAndNoFailureIsStillLoading() {
        #expect(ReferralCodeSlot.of(referralCode: "", loadFailed: false) == .loading)
    }
}
