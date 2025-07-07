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
}
