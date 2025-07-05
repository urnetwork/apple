//
//  UrApiService.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/5/25.
//

import Foundation
import URnetworkSdk

class UrApiService: UrApiServiceProtocol {
    
    private let api: SdkApi
    
    init(api: SdkApi) {
        self.api = api
    }
        
}

// MARK - leaderboard
extension UrApiService {
    
    /**
     * Fetches leaderboard
     */
    func getLeaderboard() async throws -> [LeaderboardEntry] {
        let args = SdkGetLeaderboardArgs()
        
        let result: SdkLeaderboardResult = try await withCheckedThrowingContinuation { continuation in
            let callback = GetLeaderboardCallback { result, err in
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                if let err = result?.error {
                    continuation.resume(
                        throwing: LeaderboardError.resultError(message: err.message))
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: LeaderboardError.resultEmpty)
                    return
                }
                
                continuation.resume(returning: result)
            }
            
            self.api.getLeaderboard(args, callback: callback)
        }
        
        var earners: [LeaderboardEntry] = []
        
        let n = result.earners?.len()
        
        guard let n = n else {
            throw LeaderboardError.earnersEmpty
        }
        
        for i in 0..<n {
            let earner = result.earners?.get(i)
            
            if let earner = earner {
                earners.append(
                    LeaderboardEntry(
                        networkId: earner.networkId,
                        networkName: earner.networkName,
                        netProvided: formatMiB(mib: earner.netMiBCount),
                        rank: i,
                        isPublic: earner.isPublic,
                        containsProfanity: earner.containsProfanity
                    ))
            }
        }
        
        return earners
    }
    
    /**
     * Set network ranking public
     * Networks are by default private in the leaderboard
     */
    func setNetworkRankingPublic(_ isPublic: Bool) async throws {
        
        let _: SdkSetNetworkRankingPublicResult = try await withCheckedThrowingContinuation { [weak self] continuation in

            guard let self = self else { return }

            let callback = SetLeaderboardVisibilityCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                if let err = result?.error {
                    continuation.resume(
                        throwing: LeaderboardError.resultError(message: err.message))
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: LeaderboardError.resultEmpty)
                    return
                }

                continuation.resume(returning: result)

            }

            let args = SdkSetNetworkRankingPublicArgs()
            args.isPublic = isPublic

            api.setNetworkLeaderboardPublic(args, callback: callback)

        }
    }
    
    /**
     * Get current network ranking
     */
    func getLeaderboardRanking() async throws -> SdkGetNetworkRankingResult {
        
        return try await withCheckedThrowingContinuation {
            [weak self] continuation in

            guard let self = self else { return }

            let callback = GetNetworkRankingCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                if let err = result?.error {
                    continuation.resume(
                        throwing: LeaderboardError.resultError(message: err.message))
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: LeaderboardError.resultEmpty)
                    return
                }

                continuation.resume(returning: result)

            }

            api.getNetworkLeaderboardRanking(callback)

        }
    }
    
}


/**
 * Callback classes
 */
private class GetLeaderboardCallback: SdkCallback<
    SdkLeaderboardResult, SdkGetLeaderboardCallbackProtocol
>, SdkGetLeaderboardCallbackProtocol
{
    func result(_ result: SdkLeaderboardResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SetLeaderboardVisibilityCallback: SdkCallback<
    SdkSetNetworkRankingPublicResult, SdkSetNetworkLeaderboardPublicCallbackProtocol
>, SdkSetNetworkLeaderboardPublicCallbackProtocol
{
    func result(_ result: SdkSetNetworkRankingPublicResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetNetworkRankingCallback: SdkCallback<
    SdkGetNetworkRankingResult, SdkGetNetworkLeaderboardRankingCallbackProtocol
>, SdkGetNetworkLeaderboardRankingCallbackProtocol
{
    func result(_ result: SdkGetNetworkRankingResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

/**
 * Error enums
 */
enum LeaderboardError: Error {
    case isLoading
    case resultError(message: String)
    case resultEmpty
    case earnersEmpty
    case unknown
}

enum NetworkRankingError: Error {
    case isLoading
    case resultError(message: String)
    case resultEmpty
    case unknown
}

enum SetRankingVisibilityError: Error {
    case isLoading
    case resultError(message: String)
    case resultEmpty
    case unknown
}
