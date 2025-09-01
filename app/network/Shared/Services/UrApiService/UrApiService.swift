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
    
    let domain = "UrApiService"
    
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
        
        let _: SdkSetNetworkRankingPublicResult = try await withCheckedThrowingContinuation { continuation in

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
        
        return try await withCheckedThrowingContinuation { continuation in

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

// MARK - feedback
extension UrApiService {
    
    func sendFeedback(
        feedback: String,
        starCount: Int
    ) async throws -> SdkFeedbackSendResult {
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = SendFeedbackCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result else {
                    continuation.resume(throwing: SendFeedbackError.emptyResult)
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkFeedbackSendArgs()
            let needs = SdkFeedbackSendNeeds()
            needs.other = feedback
            args.needs = needs
            args.starCount = starCount
            
            api.sendFeedback(args, callback: callback)
            
        }
    }
    
}

// MARK - provider list calls
extension UrApiService {
    
    /**
     * Search providers
     */
    func searchProviders(_ query: String) async throws -> SdkFilteredLocations {
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = FindLocationsCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                let filteredLocations = SdkGetFilteredLocationsFromResult(result, query)
                
                guard let filteredLocations = filteredLocations else {
                    continuation.resume(throwing: FetchProvidersError.noProvidersFound)
                    return
                }
                
                continuation.resume(returning: filteredLocations)
                
            }
            
            let args = SdkFindLocationsArgs()
            args.query = query

            api.findProviderLocations(args, callback: callback)
        }
    }
    
    /**
     * Get all providers
     */
    func getAllProviders() async throws -> SdkFilteredLocations {
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            
            guard let self = self else { return }
            
            let callback = FindLocationsCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                let filter = ""
                let filteredLocations = SdkGetFilteredLocationsFromResult(result, filter)
                
                guard let filteredLocations = filteredLocations else {
                    continuation.resume(throwing: FetchProvidersError.noProvidersFound)
                    return
                }
                
                continuation.resume(returning: filteredLocations)
                
            }
            
            api.getProviderLocations(callback)
            
        }
    }
}

// MARK - authentication
extension UrApiService {
    
    func authLogin(_ args: SdkAuthLoginArgs) async throws -> AuthLoginResult {
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = AuthLoginCallback { result, error in
                
                if let error {

                    continuation.resume(throwing: error)
                    
                    return
                }
                
                guard let result else {
                    
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result found"]))
                    
                    return
                }
                
                if let resultError = result.error {
                    
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "result.error exists \(resultError.message)"]))
                    
                    return
                }
                
                // JWT exists, proceed to authenticate network
                if let jwt = result.network?.byJwt {
                    continuation.resume(returning: .login(jwt))
                    return
                }
                
                // user auth requires password
                if let authAllowed = result.authAllowed {
                    
                    if authAllowed.contains("password") {
                        
                        /**
                         * Login
                         */
                        continuation.resume(returning: .promptPassword(result))
                        
                    } else {
                        
                        /**
                         * Trying to login with the wrong account
                         * ie email is used with google, but trying that same email with apple
                         */
                        
                        var acceptedAuthMethods: [String] = []

                        // loop authAllowed
                        for i in 0..<authAllowed.len() {
                            acceptedAuthMethods.append(authAllowed.get(i))
                        }

                        guard acceptedAuthMethods.isEmpty else {

                            let errMessage = "Please login with one of: \(acceptedAuthMethods.joined(separator: ", "))."

                            continuation.resume(returning: .incorrectAuth(errMessage))

                            return
                        }
                        
                    }
                    
                    return
                    
                }
                               
                /**
                 * Create new network
                 */
                continuation.resume(returning: .create(args))
                
            }
            
            api.authLogin(args, callback: callback)

        }
    }
    
    func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult {
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = NetworkCreateCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                if let result = result {
                    
                    if let resultError = result.error {

                        continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                        
                        return
                        
                    }
                    
                    if result.verificationRequired != nil {
                        continuation.resume(returning: .successWithVerificationRequired)
                        return
                    }
                    
                    if let network = result.network {
                        
                        continuation.resume(returning: .successWithJwt(network.byJwt))
                        return
                        
                    } else {
                        continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network object found in result"]))
                        return
                    }
                    
                }
                
            }
            
            api.networkCreate(args, callback: callback)
            
        }
    }
    
    func upgradeGuest(_ args: SdkUpgradeGuestArgs) async throws -> LoginNetworkResult {
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = UpgradeGuestCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                if let result = result {
                    
                    if let resultError = result.error {

                        continuation.resume(throwing: UrApiError.resultError(message: resultError.message))
                        
                        return
                        
                    }
                    
                    if result.verificationRequired != nil {
                        continuation.resume(returning: .successWithVerificationRequired)
                        return
                    }
                    
                    if let network = result.network {
                        
                        continuation.resume(returning: .successWithJwt(network.byJwt))
                        return
                        
                    } else {
                        continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network found in result"]))
                        return
                    }
                    
                }
                
            }
            
            api.upgradeGuest(args, callback: callback)
            
        }
    }
    
    func createAuthCode() async throws -> SdkAuthCodeCreateResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = AuthCodeCreateCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No result found in callback"]))
                    return
                }
                
                if result.error != nil {
                    print("createAuthCode.error result is \(String(describing: result.error?.message))")
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Error in result"]))
                    return
                    
                }
                
                print("createAuthCode result is \(result)")
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkAuthCodeCreateArgs()
            args.durationMinutes = 5
            args.uses = 1

            api.authCodeCreate(args, callback: callback)
            
        }
    }
    
}

// MARK - referral code
extension UrApiService {
    
    func validateReferralCode(_ code: String) async throws -> SdkValidateReferralCodeResult {
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = ValidateReferralCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: UrApiError.resultEmpty)
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkValidateReferralCodeArgs()
            
            args.referralCode = code
            
            api.validateReferralCode(args, callback: callback)
            
        }
    }
    
}

// MARK - subscription calls
extension UrApiService {
    
    func fetchSubscriptionBalance() async throws -> SdkSubscriptionBalanceResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = GetSubscriptionBalanceCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "GetSubscriptionBalanceCallback result is nil"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            api.subscriptionBalance(callback)
        }
        
    }
    
}

// MARK - blocking locations
extension UrApiService {
    
    func blockLocation(_ locationId: SdkId) async throws -> SdkNetworkBlockLocationResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = BlockLocationCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "BlockLocationCallback result is nil"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkNetworkBlockLocationArgs()
            args.locationId = locationId
            
            api.networkBlockLocation(args, callback: callback)
        }
        
    }
    
    func unblockLocation(_ locationId: SdkId) async throws -> SdkNetworkUnblockLocationResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = UnblockLocationCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "UnblockLocationCallback result is nil"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkNetworkUnblockLocationArgs()
            args.locationId = locationId
            
            api.networkUnblockLocation(args, callback: callback)
        }
        
    }
    
    func getBlockedLocations() async throws -> SdkGetNetworkBlockedLocationsResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = GetNetworkBlockedLocationsCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "UnblockLocationCallback result is nil"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            api.getNetworkBlockedLocations(callback)
        }
        
    }
    
}

// MARK: Settings
extension UrApiService {
    
    func deleteAccount() async throws -> SdkNetworkDeleteResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = NetworkDeleteCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: SendPasswordResetLinkError.resultInvalid)
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            api.networkDelete(callback)
            
        }
        
    }
    
    func getReferralNetwork() async throws -> SdkGetReferralNetworkResult {
        
        return try await withCheckedThrowingContinuation { continuation in

            let callback = GetNetworkReferralCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "getReferralNetwork result is nil"]))
                    return
                }

                continuation.resume(returning: result)
            }

            api.getReferralNetwork(callback)

        }
    }
    
    func setNetworkReferral(_ referralCode: String) async throws -> SdkSetNetworkReferralResult {
        
        return try await withCheckedThrowingContinuation { continuation in

            let callback = UpdateReferralNetworkCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkSetNetworkReferralResult result is nil"]))
                    return
                }

                continuation.resume(returning: result)
            }
            
            let args = SdkSetNetworkReferralArgs()
            args.referralCode = referralCode

            api.setNetworkReferral(args, callback: callback)

        }
        
    }
    
    func unlinkReferralNetwork() async throws -> SdkUnlinkReferralNetworkResult {
        return try await withCheckedThrowingContinuation { continuation in

            let callback = UnlinkReferralNetworkCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UpdateReferralNetworkViewModel", code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkUnlinkReferralNetworkResult result is nil"]))
                    return
                }

                continuation.resume(returning: result)
            }
            
            api.unlinkReferralNetwork(callback)

        }
    }
    
}

// MARK: network reliability
extension UrApiService {
    
    func getNetworkReliability() async throws -> SdkGetNetworkReliabilityResult {
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = GetNetworkReliabilityCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "getNetworkReliability result is nil"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            api.getNetworkReliability(callback)
        }
        
    }
    
}

// MARK: wallet
extension UrApiService {
    
    func validateWalletAddress(address: String, chain: String) async throws -> Bool {
        
        return try await withCheckedThrowingContinuation { continuation in

            let callback = ValidateAddressCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "validateWalletAddress result is nil"]))
                    return
                }

                continuation.resume(returning: result.valid)
            }

            let args = SdkWalletValidateAddressArgs()
            args.address = address
            args.chain = chain

            api.walletValidateAddress(args, callback: callback)
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

private class SendFeedbackCallback: SdkCallback<SdkFeedbackSendResult, SdkSendFeedbackCallbackProtocol>, SdkSendFeedbackCallbackProtocol {
    func result(_ result: SdkFeedbackSendResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class FindLocationsCallback: SdkCallback<SdkFindLocationsResult, SdkFindLocationsCallbackProtocol>, SdkFindLocationsCallbackProtocol {
    func result(_ result: SdkFindLocationsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class AuthLoginCallback: SdkCallback<SdkAuthLoginResult, SdkAuthLoginCallbackProtocol>, SdkAuthLoginCallbackProtocol {
    func result(_ result: SdkAuthLoginResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ValidateReferralCallback: SdkCallback<SdkValidateReferralCodeResult, SdkValidateReferralCodeCallbackProtocol>, SdkValidateReferralCodeCallbackProtocol {
    func result(_ result: SdkValidateReferralCodeResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class UpgradeGuestCallback: SdkCallback<SdkUpgradeGuestResult, SdkUpgradeGuestCallbackProtocol>, SdkUpgradeGuestCallbackProtocol {
    func result(_ result: SdkUpgradeGuestResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetSubscriptionBalanceCallback: SdkCallback<SdkSubscriptionBalanceResult, SdkSubscriptionBalanceCallbackProtocol>, SdkSubscriptionBalanceCallbackProtocol {
    
    func result(_ result: SdkSubscriptionBalanceResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class BlockLocationCallback: SdkCallback<SdkNetworkBlockLocationResult, SdkNetworkBlockLocationCallbackProtocol>, SdkNetworkBlockLocationCallbackProtocol {
    
    func result(_ result: SdkNetworkBlockLocationResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class UnblockLocationCallback: SdkCallback<SdkNetworkUnblockLocationResult, SdkNetworkUnblockLocationCallbackProtocol>, SdkNetworkUnblockLocationCallbackProtocol {
    
    func result(_ result: SdkNetworkUnblockLocationResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetNetworkBlockedLocationsCallback: SdkCallback<SdkGetNetworkBlockedLocationsResult, SdkGetNetworkBlockedLocationsCallbackProtocol>, SdkGetNetworkBlockedLocationsCallbackProtocol {
    
    func result(_ result: SdkGetNetworkBlockedLocationsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class AuthCodeCreateCallback: SdkCallback<SdkAuthCodeCreateResult, SdkAuthCodeCreateCallbackProtocol>, SdkAuthCodeCreateCallbackProtocol {
    
    func result(_ result: SdkAuthCodeCreateResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetNetworkReliabilityCallback: SdkCallback<SdkGetNetworkReliabilityResult, SdkGetNetworkReliabilityCallbackProtocol>, SdkGetNetworkReliabilityCallbackProtocol {
    
    func result(_ result: SdkGetNetworkReliabilityResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ValidateAddressCallback: SdkCallback<SdkWalletValidateAddressResult, SdkWalletValidateAddressCallbackProtocol>, SdkWalletValidateAddressCallbackProtocol {
    func result(_ result: SdkWalletValidateAddressResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class NetworkDeleteCallback: SdkCallback<SdkNetworkDeleteResult, SdkNetworkDeleteCallbackProtocol>, SdkNetworkDeleteCallbackProtocol {
    func result(_ result: SdkNetworkDeleteResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetNetworkReferralCallback: SdkCallback<SdkGetReferralNetworkResult, SdkGetReferralNetworkCallbackProtocol>, SdkGetReferralNetworkCallbackProtocol {
    func result(_ result: SdkGetReferralNetworkResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class UpdateReferralNetworkCallback: SdkCallback<SdkSetNetworkReferralResult, SdkSetNetworkReferralCallbackProtocol>, SdkSetNetworkReferralCallbackProtocol {
    func result(_ result: SdkSetNetworkReferralResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class UnlinkReferralNetworkCallback: SdkCallback<SdkUnlinkReferralNetworkResult, SdkUnlinkReferralNetworkCallbackProtocol>, SdkUnlinkReferralNetworkCallbackProtocol {
    func result(_ result: SdkUnlinkReferralNetworkResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

/**
 * Error enums
 */

// general errors
enum UrApiError: Error {
    case resultEmpty
    case resultError(message: String)
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

enum SendFeedbackError: Error {
    case isSending
    case emptyResult
    case invalidArgs
}

enum FetchProvidersError: Error {
    case noProvidersFound
}

enum LoginError: Error {
    case appleLoginFailed
    case googleLoginFailed
    case googleNoResult
    case googleNoIdToken
    case inProgress
    case incorrectAuth(_ authAllowed: String)
}

enum LoginNetworkResult {
    case successWithJwt(String)
    case successWithVerificationRequired
    case failure(Error)
}

enum NetworkDeleteError: Error {
    case inProgress
    case resultInvalid
}

enum UpdateReferralNetworkError: Error {
    case inProgress
    case resultInvalid
    case unknown
}


