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

    func authWalletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult {
        return SdkAuthWalletChallengeResult()
    }
    
    func validateReferralCode(_ code: String) async throws -> SdkValidateReferralCodeResult {
        SdkValidateReferralCodeResult()
    }
    
    func issueOnboardingOffer(surface: String, storefrontCountry: String?) async throws -> SdkOnboardingOffer {
        let offer = SdkOnboardingOffer()
        offer.state = "active"
        offer.percentOff = 25
        offer.monthsFree = 3
        offer.firstYearUsd = 30
        offer.regularYearUsd = 40
        offer.expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 24 * 3600))
        return offer
    }

    func onboardingFeedbackToken(_ token: String, rating: Int, reason: String) async throws -> SdkOnboardingFeedbackTokenResult {
        let result = SdkOnboardingFeedbackTokenResult()
        result.ok = true
        result.rating = rating
        result.reason = reason
        return result
    }

    func fetchSubscriptionBalance(storefrontCountry: String?) async throws -> SdkSubscriptionBalanceResult {
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
    
    func loginWithSeedphrase(seedphrase: String) async throws -> AuthLoginResult {
        return AuthLoginResult.failure(LoginError.inProgress)
    }
    
    func createInstantAccount(referralCode: String?, productUpdatesOptOut: Bool) async throws -> (jwt: String, seedphrase: String) {
        return ("mock-jwt", "mock seedphrase words here for testing purposes only")
    }
    
    func generateSeedphrase() async throws -> SdkGenerateSeedphraseResult {
        return SdkGenerateSeedphraseResult()
    }
    
    func regenerateSeedphrase() async throws -> SdkRegenerateSeedphraseResult {
        return SdkRegenerateSeedphraseResult()
    }
    
    func addAuth(_ args: SdkAddAuthArgs) async throws -> SdkAddAuthResult {
        return SdkAddAuthResult()
    }
    
    func removeAuth(authType: String) async throws -> SdkRemoveAuthResult {
        return SdkRemoveAuthResult()
    }
    
    func changeNetworkName(_ newName: String) async throws -> SdkChangeNetworkNameResult {
        return SdkChangeNetworkNameResult()
    }
    
    func claimNetworkName(_ newName: String) async throws -> SdkClaimNetworkNameResult {
        return SdkClaimNetworkNameResult()
    }
    
    func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult {
        return SdkRedeemBalanceCodeResult()
    }
    
    func getRedeemedBalanceCodes() async throws -> SdkGetNetworkRedeemedBalanceCodesResult {
        return SdkGetNetworkRedeemedBalanceCodesResult()
    }
    
    func authCodeLogin(_ args: SdkAuthCodeLoginArgs) async throws -> SdkAuthCodeLoginResult {
        return SdkAuthCodeLoginResult()
    }

    func getNetworkClients() async throws -> SdkNetworkClientsResult {
        return SdkNetworkClientsResult()
    }

    func deviceSetName(deviceId: SdkId, deviceName: String) async throws -> Void {
        return
    }

}
