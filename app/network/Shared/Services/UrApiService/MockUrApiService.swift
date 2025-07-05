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
    
}
