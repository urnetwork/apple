//
//  LeaderboardViewModel.swift
//  app
//
//  Created by Stuart Kuentzel on 2025/05/21.
//
import Foundation
import URnetworkSdk
import SwiftUI
import Combine

extension LeaderboardView {
    
    @MainActor
    class ViewModel: ObservableObject {
        
        private var api: SdkApi
        
        @Published private(set) var networkRankingPublic: Bool = false
        @Published private(set) var leaderboardEarners: [SdkLeaderboardEarner] = []
        
        @Published private(set) var networkRanking: SdkNetworkRanking? = nil
        @Published private(set) var isLoading: Bool = false
        @Published private(set) var isInitializing: Bool = true
        
        init(api: SdkApi) {
            self.api = api
            
            Task {
                await fetchLeaderboardData()
            }
            
        }
        
        func fetchLeaderboardData() async {
            
            if (isLoading) {
                return
            }
            
            self.isLoading = true
            
            // Use Swift concurrency to run both API calls in parallel
            async let rankingResult = getRanking()
            async let leaderboardResult = getLeaderboard()
            
            // Wait for both to complete
            let (ranking, leaderboard) = await (rankingResult, leaderboardResult)
            
            // Handle results if needed
            switch (ranking, leaderboard) {
            case (.success, .success):
                print("Both API calls completed successfully")
            case (.failure(let rankingError), _):
                print("Ranking error: \(rankingError)")
            case (_, .failure(let leaderboardError)):
                print("Leaderboard error: \(leaderboardError)")
            }
            
            self.isLoading = false
            if (self.isInitializing) {
                self.isInitializing = false
            }
            
        }
        
        private func getRanking() async -> Result<Void, Error> {
            
            do {
                
                let result: SdkGetNetworkRankingResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                    
                    guard let self = self else { return }
                    
                    let callback = GetNetworkRankingCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        if let err = result?.error {
                            continuation.resume(throwing: LeaderboardError.resultError(message: err.message))
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
                
                self.networkRanking = result.networkRanking

                return .success(())
                
            } catch(let error) {
                print("get network ranking error \(error)")
                
                return .failure(error)
            }
            
        }
        
        private func getLeaderboard() async -> Result<Void, Error> {
            
            do {
                
                let result: SdkLeaderboardResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                    
                    guard let self = self else { return }
                    
                    let callback = GetLeaderboardCallback { result, err in
                        
                        if let err = err {
                            continuation.resume(throwing: err)
                            return
                        }
                        
                        if let err = result?.error {
                            continuation.resume(throwing: LeaderboardError.resultError(message: err.message))
                            return
                        }
                        
                        guard let result = result else {
                            continuation.resume(throwing: LeaderboardError.resultEmpty)
                            return
                        }
                        
                        continuation.resume(returning: result)
                        
                    }
                    
                    let args = SdkGetLeaderboardArgs()
                    
                    api.getLeaderboard(args, callback: callback)
                    
                }
                
                var earners: [SdkLeaderboardEarner] = []
                
                let n = result.earners?.len()
                
                guard let n = n else {
                    return .failure(LeaderboardError.earnersEmpty)
                }
                
                for i in 0..<n {
                    let earner = result.earners?.get(i)
                    
                    if let earner = earner {
                        earners.append(earner)
                    }
                }
                
                self.leaderboardEarners = earners
                
                return .success(())
                
            } catch(let error) {
                print("get leaderboard error \(error)")
                
                return .failure(error)
            }
            
        }
        
        func setNetworkRankingPublic() {}
        
    }
    
}

private class GetLeaderboardCallback: SdkCallback<SdkLeaderboardResult, SdkGetLeaderboardCallbackProtocol>, SdkGetLeaderboardCallbackProtocol {
    func result(_ result: SdkLeaderboardResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetNetworkRankingCallback: SdkCallback<SdkGetNetworkRankingResult, SdkGetNetworkLeaderboardRankingCallbackProtocol>, SdkGetNetworkLeaderboardRankingCallbackProtocol {
    func result(_ result: SdkGetNetworkRankingResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

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

