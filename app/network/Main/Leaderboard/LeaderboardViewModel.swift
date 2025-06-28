//
//  LeaderboardViewModel.swift
//  app
//
//  Created by Stuart Kuentzel on 2025/05/21.
//
import Foundation
import SwiftUI
import URnetworkSdk

extension LeaderboardView {

    @MainActor
    class ViewModel: ObservableObject {

        private var api: SdkApi

        @Published var networkRankingPublic: Bool = false {
            didSet {
                Task {
                    await setNetworkRankingPublic(networkRankingPublic)
                }
            }
        }

        @Published private(set) var leaderboardEarners: [LeaderboardEntry] = []

        // @Published private(set) var networkRanking: SdkNetworkRanking? = nil

        @Published private(set) var networkRank: Int = 0
        @Published private(set) var netProvidedFormatted: String = ""

        @Published private(set) var isLoading: Bool = false
        @Published private(set) var isInitializing: Bool = true

        @Published private(set) var isSettingRankingVisibility: Bool = false

        init(api: SdkApi) {
            self.api = api

            Task {
                await fetchLeaderboardData()
            }

        }

        func fetchLeaderboardData() async {

            if isLoading {
                return
            }

            self.isLoading = true

            async let rankingResult = getRanking()
            async let leaderboardResult = getLeaderboard()

            // Wait for both to complete
            let (ranking, leaderboard) = await (rankingResult, leaderboardResult)

            switch (ranking, leaderboard) {
            case (.success, .success):
                print("Both API calls completed successfully")
            case (.failure(let rankingError), _):
                print("Ranking error: \(rankingError)")
            case (_, .failure(let leaderboardError)):
                print("Leaderboard error: \(leaderboardError)")
            }

            self.isLoading = false
            if self.isInitializing {
                self.isInitializing = false
            }

        }

        private func getRanking() async -> Result<Void, Error> {

            do {

                let result: SdkGetNetworkRankingResult = try await withCheckedThrowingContinuation {
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

                if let networkRanking = result.networkRanking {
                    self.networkRankingPublic = networkRanking.leaderboardPublic
                    self.networkRank = networkRanking.leaderboardRank
                    self.netProvidedFormatted = self.formatByteSize(mib: networkRanking.netMiBCount)
                }

                return .success(())

            } catch (let error) {
                print("get network ranking error \(error)")

                return .failure(error)
            }

        }

        private func getLeaderboard() async -> Result<Void, Error> {

            do {

                let result: SdkLeaderboardResult = try await withCheckedThrowingContinuation {
                    [weak self] continuation in

                    guard let self = self else { return }

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

                    let args = SdkGetLeaderboardArgs()

                    api.getLeaderboard(args, callback: callback)

                }

                var earners: [LeaderboardEntry] = []

                let n = result.earners?.len()

                guard let n = n else {
                    return .failure(LeaderboardError.earnersEmpty)
                }

                for i in 0..<n {
                    let earner = result.earners?.get(i)

                    if let earner = earner {

                        earners.append(
                            LeaderboardEntry(
                                networkId: earner.networkId,
                                networkName: earner.networkName,
                                netProvided: self.formatByteSize(mib: earner.netMiBCount),
                                rank: i,
                                isPublic: earner.isPublic,
                                containsProfanity: earner.containsProfanity
                            ))
                    }
                }

                self.leaderboardEarners = earners

                return .success(())

            } catch (let error) {
                print("get leaderboard error \(error)")

                return .failure(error)
            }

        }

        private func formatByteSize(mib: Float) -> String {

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 2
            
            let pib: Float = 1024 * 1024 * 1024
            let tib: Float = 1024 * 1024
            let gib: Float = 1024

            // 1 GiB = 1024 MiB
            // if mib >= 1_048_576 {  // 1 PiB = 1024 TiB = 1,048,576 GiB
            if mib >= pib {
                let pib = mib / pib
                let formatted =
                    formatter.string(from: NSNumber(value: pib)) ?? String(format: "%.2f", pib)
                return "\(formatted) PiB"
            } else if mib >= tib {  // 1 TiB = 1024 GiB = 1,048,576 MiB
                let tib = mib / tib
                let formatted =
                    formatter.string(from: NSNumber(value: tib)) ?? String(format: "%.2f", tib)
                return "\(formatted) TiB"
            } else if mib >= gib {  // 1 GiB = 1024 MiB
                let gib = mib / gib
                let formatted =
                    formatter.string(from: NSNumber(value: gib)) ?? String(format: "%.2f", gib)
                return "\(formatted) GiB"
            } else {
                let formatted =
                    formatter.string(from: NSNumber(value: mib)) ?? String(format: "%.2f", mib)
                return "\(formatted) MiB"
            }
        }

        func setNetworkRankingPublic(_ isPublic: Bool) async -> Result<Void, Error> {

            if self.isSettingRankingVisibility {
                return .failure(SetRankingVisibilityError.isLoading)
            }

            self.isSettingRankingVisibility = true

            do {

                let _: SdkSetNetworkRankingPublicResult = try await withCheckedThrowingContinuation
                { [weak self] continuation in

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
                
                let _ = await self.getLeaderboard()

                self.isSettingRankingVisibility = false

                return .success(())

            } catch (let error) {
                print("set ranking visibility error \(error)")

                self.isSettingRankingVisibility = false

                return .failure(error)
            }

        }

    }

}

private class GetLeaderboardCallback: SdkCallback<
    SdkLeaderboardResult, SdkGetLeaderboardCallbackProtocol
>, SdkGetLeaderboardCallbackProtocol
{
    func result(_ result: SdkLeaderboardResult?, err: Error?) {
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

private class SetLeaderboardVisibilityCallback: SdkCallback<
    SdkSetNetworkRankingPublicResult, SdkSetNetworkLeaderboardPublicCallbackProtocol
>, SdkSetNetworkLeaderboardPublicCallbackProtocol
{
    func result(_ result: SdkSetNetworkRankingPublicResult?, err: Error?) {
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

enum SetRankingVisibilityError: Error {
    case isLoading
    case resultError(message: String)
    case resultEmpty
    case unknown
}

struct LeaderboardEntry: Identifiable {
    /**
     * This is used when passing LeaderboardEntry to lists/tables
     * ID needs to be unique. We're not using networkId, because it's an empty string if the user has their network marked as private.
     * Instead, we're using their rank, which is unique, from 0-99
     */
    let id: String
    
    let networkId: String
    let networkName: String
    let netProvided: String
    let rank: String
    let isPublic: Bool

    init(
        networkId: String,
        networkName: String,
        netProvided: String,
        rank: Int,
        isPublic: Bool,
        containsProfanity: Bool
    ) {

        self.id = "\(rank)"
        self.networkId = networkId

        self.networkName = !isPublic
            ? NSLocalizedString("Private Network", comment: "Network name when privacy is enabled")
            : containsProfanity
                ? String(networkName.prefix(1)) + String(repeating: "*", count: networkName.count - 2) + String(networkName.suffix(1))
                : networkName
        
        self.netProvided = netProvided
        self.rank = "\(rank + 1)"
        self.isPublic = isPublic
    }
}
