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
    func upgradeGuest(_ args: SdkUpgradeGuestArgs) async throws -> LoginNetworkResult
    
    /**
     * Subscription
     */
    func fetchSubscriptionBalance() async throws -> SdkSubscriptionBalanceResult
    
    /**
     * Network Block locations
     */
    func blockLocation(_ locationId: SdkId) async throws -> SdkNetworkBlockLocationResult
    func unblockLocation(_ locationId: SdkId) async throws -> SdkNetworkUnblockLocationResult
    func getBlockedLocations() async throws -> SdkGetNetworkBlockedLocationsResult
}
