//
//  MockUrApiService.swift
//  networkTests
//
//  Created by Stuart Kuentzel on 7/5/25.
//

import Foundation
import URnetworkSdk

class MockUrApiService: UrApiServiceProtocol {
    func getLeaderboard() async throws -> [LeaderboardEntry] {
        return []
    }
    
    func getLeaderboardRanking() async throws -> SdkGetNetworkRankingResult {
        return SdkGetNetworkRankingResult()
    }
    
    func setNetworkRankingPublic(_ isPublic: Bool) async throws {
        return
    }
    
    func sendFeedback(feedback: String, starCount: Int) async throws -> SdkFeedbackSendResult {
        return SdkFeedbackSendResult()
    }
    
    func getAllProviders() async throws -> SdkFilteredLocations {
        return SdkFilteredLocations()
    }
    
    func searchProviders(_ query: String) async throws -> SdkFilteredLocations {
        return SdkFilteredLocations()
    }
    
    func authLogin(_ args: SdkAuthLoginArgs) async throws -> AuthLoginResult {
        return AuthLoginResult.failure(LoginError.appleLoginFailed)
    }
    
    func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult {
        return LoginNetworkResult.failure(LoginError.appleLoginFailed)
    }
    
    func validateReferralCode(_ code: String) async throws -> SdkValidateReferralCodeResult {
        SdkValidateReferralCodeResult()
    }
    
    func upgradeGuest(_ args: SdkUpgradeGuestArgs) async throws -> LoginNetworkResult {
        return LoginNetworkResult.failure(LoginError.appleLoginFailed)
    }
    
    func fetchSubscriptionBalance() async throws -> SdkSubscriptionBalanceResult {
        return SdkSubscriptionBalanceResult()
    }
    
    func blockLocation(_ locationId: SdkId) async throws -> SdkNetworkBlockLocationResult {
        return SdkNetworkBlockLocationResult()
    }
    
    func unblockLocation(_ locationId: SdkId) async throws -> SdkNetworkUnblockLocationResult {
        return SdkNetworkUnblockLocationResult()
    }
    
    func getBlockedLocations() async throws -> SdkGetNetworkBlockedLocationsResult {
        return SdkGetNetworkBlockedLocationsResult()
    }
    
    func createAuthCode() async throws -> SdkAuthCodeCreateResult {
        return SdkAuthCodeCreateResult()
    }
    
    func getNetworkReliability() async throws -> SdkGetNetworkReliabilityResult {
        return SdkGetNetworkReliabilityResult()
    }
    
    func validateWalletAddress(address: String, chain: String) async throws -> Bool {
        return true
    }
    
    func deleteAccount() async throws -> SdkNetworkDeleteResult {
        return SdkNetworkDeleteResult()
    }
    
    func getReferralNetwork() async throws -> SdkGetReferralNetworkResult {
        return SdkGetReferralNetworkResult()
    }
    
    func setNetworkReferral(_ referralCode: String) async throws -> SdkSetNetworkReferralResult {
        SdkSetNetworkReferralResult()
    }
    
    func unlinkReferralNetwork() async throws -> SdkUnlinkReferralNetworkResult {
        return SdkUnlinkReferralNetworkResult()
    }
    
    func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult {
        return SdkRedeemBalanceCodeResult()
    }
    
}
