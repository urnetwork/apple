//
//  UrApiServiceProtocol.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/5/25.
//

import Foundation
import URnetworkSdk

protocol UrApiServiceProtocol {
    
    /**
     * Leaderboard
     */
    func getLeaderboard() async throws -> [LeaderboardEntry]
    func setNetworkRankingPublic(_ isPublic: Bool) async throws -> Void
    func getLeaderboardRanking() async throws -> SdkGetNetworkRankingResult
    
    /**
     * Feedback
     */
    func sendFeedback(feedback: String, starCount: Int) async throws -> SdkFeedbackSendResult
    
    /**
     * Provider list
     */
    func searchProviders(_ query: String) async throws -> SdkFilteredLocations
    func getAllProviders() async throws -> SdkFilteredLocations
    
    /**
     * Authentication
     */
    func authLogin(_ args: SdkAuthLoginArgs) async throws -> AuthLoginResult
    func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult
    func validateReferralCode(_ code: String) async throws -> SdkValidateReferralCodeResult
    func createAuthCode() async throws -> SdkAuthCodeCreateResult
    func authCodeLogin(_ args: SdkAuthCodeLoginArgs) async throws -> SdkAuthCodeLoginResult
    func authWalletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult
    
    /**
     * Subscription
     */
    func fetchSubscriptionBalance() async throws -> SdkSubscriptionBalanceResult
    func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult
    func getRedeemedBalanceCodes() async throws -> SdkGetNetworkRedeemedBalanceCodesResult
    
    /**
     * Network Block locations
     */
    func blockLocation(_ locationId: SdkId) async throws -> SdkNetworkBlockLocationResult
    func unblockLocation(_ locationId: SdkId) async throws -> SdkNetworkUnblockLocationResult
    func getBlockedLocations() async throws -> SdkGetNetworkBlockedLocationsResult
    
    /**
     * Network reliability
     */
    func getNetworkReliability() async throws -> SdkGetNetworkReliabilityResult
    
    /**
     * Wallet
     */
    func validateWalletAddress(address: String, chain: String) async throws -> Bool
    
    /**
     * Settings
     */
    func loginWithSeedphrase(seedphrase: String) async throws -> AuthLoginResult
    func createInstantAccount() async throws -> (jwt: String, seedphrase: String)
    func deleteAccount() async throws -> SdkNetworkDeleteResult
    func getReferralNetwork() async throws -> SdkGetReferralNetworkResult
    func setNetworkReferral(_ referralCode: String) async throws -> SdkSetNetworkReferralResult
    func unlinkReferralNetwork() async throws -> SdkUnlinkReferralNetworkResult

    /**
     * Account Management — Seedphrase
     */
    func generateSeedphrase() async throws -> SdkGenerateSeedphraseResult
    func regenerateSeedphrase() async throws -> SdkRegenerateSeedphraseResult

    /**
     * Account Management — Auth Methods
     */
    func addAuth(_ args: SdkAddAuthArgs) async throws -> SdkAddAuthResult
    func removeAuth(authType: String) async throws -> SdkRemoveAuthResult

    /**
     * Account Management — Network Name
     */
    func changeNetworkName(_ newName: String) async throws -> SdkChangeNetworkNameResult
    func claimNetworkName(_ newName: String) async throws -> SdkClaimNetworkNameResult

    /**
     * Device
     */
    func getNetworkClients() async throws -> SdkNetworkClientsResult
    func deviceSetName(deviceId: SdkId, deviceName: String) async throws -> Void
}
