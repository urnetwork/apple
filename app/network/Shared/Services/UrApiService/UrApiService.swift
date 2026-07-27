//
//  UrApiService.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/5/25.
//

import Foundation
import URnetworkSdk

class UrApiService: UrApiServiceProtocol {
    
    // Resolved live on every call instead of captured once at init. This
    // mirrors Android's `application.api` (a `get() = networkSpaceManagerProvider
    // .getNetworkSpace()?.api` computed property) so that switching the
    // active network space (Settings > Change Network API) is picked up
    // immediately by any in-flight or new API call, without needing to
    // tear down and recreate the whole view hierarchy that holds this
    // service (which proved unreliable via SwiftUI .id() invalidation).
    private let apiProvider: () -> SdkApi?
    private var api: SdkApi? {
        apiProvider()
    }
    
    let domain = "UrApiService"
    
    /// Fixed-api initializer, kept for call sites/tests that already have a
    /// concrete `SdkApi` and don't need to react to network switches (e.g.
    /// once a device is fully initialized and logged in, the api rarely
    /// changes for the lifetime of that screen).
    init(api: SdkApi) {
        self.apiProvider = { api }
    }

    /// Live-provider initializer. Pass a closure that always resolves the
    /// current api (e.g. `{ deviceManager.api }`) so this service tracks
    /// network-space changes made while the view using it is still on
    /// screen (the login flow, most notably).
    init(apiProvider: @escaping () -> SdkApi?) {
        self.apiProvider = apiProvider
    }

    private func requireApi() throws -> SdkApi {
        guard let api else {
            throw NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "No active network API available"])
        }
        return api
    }

    private func nonEmptyJwt(_ jwt: String, context: String) -> Result<String, Error> {
        guard !jwt.isEmpty else {
            return .failure(NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "\(context) returned empty byJWT"]))
        }

        return .success(jwt)
    }
        
}

// MARK - leaderboard
extension UrApiService {
    
    /**
     * Fetches leaderboard
     */
    func getLeaderboard() async throws -> [LeaderboardEntry] {
        let args = SdkGetLeaderboardArgs()
        
        let api = try requireApi()
        
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
            
            api.getLeaderboard(args, callback: callback)
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
        
        let api = try requireApi()
        
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
        
        let api = try requireApi()
        
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
        let api = try requireApi()
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
        let api = try requireApi()
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
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in
            
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
        let api = try requireApi()
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
                if let network = result.network {
                    switch self.nonEmptyJwt(network.byJwt, context: "authLogin") {
                    case .success(let jwt):
                        continuation.resume(returning: .login(jwt))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
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

                        for i in 0..<authAllowed.len() {
                            acceptedAuthMethods.append(authAllowed.get(i))
                        }

                        if acceptedAuthMethods.isEmpty {
                            // no existing auth methods for this user auth —
                            // treat as a brand new network (create flow)
                            continuation.resume(returning: .create(args))
                        } else {
                            let errMessage = String(localized: "Please login with one of: \(acceptedAuthMethods.joined(separator: ", ")).")
                            continuation.resume(returning: .incorrectAuth(errMessage))
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
    
    func loginWithSeedphrase(seedphrase: String) async throws -> AuthLoginResult {
        let api = try requireApi()
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
                
                if let network = result.network {
                    switch self.nonEmptyJwt(network.byJwt, context: "loginWithSeedphrase") {
                    case .success(let jwt):
                        continuation.resume(returning: .login(jwt))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    return
                }
                
                continuation.resume(returning: .failure(NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Seedphrase login returned no network"])))
                
            }
            
            let args = SdkAuthLoginArgs()
            // Normalize: lowercase, trim, collapse multiple spaces
            let normalized = seedphrase
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            args.seedphrase = normalized
            api.authLogin(args, callback: callback)

        }
    }
    
    func createInstantAccount() async throws -> (jwt: String, seedphrase: String) {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = NetworkCreateCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "createInstantAccount returned nil result"]))
                    return
                }

                if let resultError = result.error {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                    return
                }

                if result.verificationRequired != nil {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Verification required for instant account creation"]))
                    return
                }

                guard !result.seedphrase.isEmpty else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No seedphrase in result"]))
                    return
                }

                let seedphrase = result.seedphrase

                if let network = result.network {
                    switch self.nonEmptyJwt(network.byJwt, context: "createInstantAccount") {
                    case .success(let jwt):
                        continuation.resume(returning: (jwt, seedphrase))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    return
                } else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network object found in result"]))
                    return
                }

            }

            let args = SdkNetworkCreateArgs()
            args.terms = true
            // No userAuth, password, authJwt, walletAuth — triggers seedphrase path
            api.networkCreate(args, callback: callback)
            
        }
    }
    
    func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = NetworkCreateCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: "createNetwork returned nil result"]))
                    return
                }

                if let resultError = result.error {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: -1, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                    return
                }

                if result.verificationRequired != nil {
                    continuation.resume(returning: .successWithVerificationRequired)
                    return
                }

                if let network = result.network {
                    switch self.nonEmptyJwt(network.byJwt, context: "createNetwork") {
                    case .success(let jwt):
                        continuation.resume(returning: .successWithJwt(jwt))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    return
                } else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No network object found in result"]))
                    return
                }

            }

            api.networkCreate(args, callback: callback)
            
        }
    }
    
}

// MARK: — Account Management: Seedphrase

extension UrApiService {

    func generateSeedphrase() async throws -> SdkGenerateSeedphraseResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = GenerateSeedphraseCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "generateSeedphrase returned nil result"]))
                    return
                }

                if let errMsg = result.error?.message {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    return
                }

                continuation.resume(returning: result)
            }

            let args = SdkGenerateSeedphraseArgs()
            api.generateSeedphrase(args, callback: callback)
        }
    }

    func regenerateSeedphrase() async throws -> SdkRegenerateSeedphraseResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = RegenerateSeedphraseCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "regenerateSeedphrase returned nil result"]))
                    return
                }

                if let errMsg = result.error?.message {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    return
                }

                continuation.resume(returning: result)
            }

            let args = SdkRegenerateSeedphraseArgs()
            api.regenerateSeedphrase(args, callback: callback)
        }
    }

}

// MARK: — Account Management: Auth Methods

extension UrApiService {

    func addAuth(_ args: SdkAddAuthArgs) async throws -> SdkAddAuthResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = AddAuthCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "addAuth returned nil result"]))
                    return
                }

                if let errMsg = result.error?.message {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    return
                }

                continuation.resume(returning: result)
            }

            api.addAuth(args, callback: callback)
        }
    }

    func removeAuth(authType: String) async throws -> SdkRemoveAuthResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = RemoveAuthCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "removeAuth returned nil result"]))
                    return
                }

                if let errMsg = result.error?.message {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    return
                }

                continuation.resume(returning: result)
            }

            let args = SdkRemoveAuthArgs()
            args.authType = authType
            api.removeAuth(args, callback: callback)
        }
    }

}

// MARK: — Account Management: Network Name

extension UrApiService {

    func changeNetworkName(_ newName: String) async throws -> SdkChangeNetworkNameResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = ChangeNetworkNameCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "changeNetworkName returned nil result"]))
                    return
                }

                if let errMsg = result.error?.message {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    return
                }

                continuation.resume(returning: result)
            }

            let args = SdkChangeNetworkNameArgs()
            args.newName = newName
            api.changeNetworkName(args, callback: callback)
        }
    }

    func claimNetworkName(_ newName: String) async throws -> SdkClaimNetworkNameResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = ClaimNetworkNameCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: "claimNetworkName returned nil result"]))
                    return
                }

                if let errMsg = result.error?.message {
                    continuation.resume(throwing: NSError(domain: self.domain, code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                    return
                }

                continuation.resume(returning: result)
            }

            let args = SdkClaimNetworkNameArgs()
            args.newName = newName
            api.claimNetworkName(args, callback: callback)
        }
    }

}

// MARK: wallet

extension UrApiService {

    func createAuthCode() async throws -> SdkAuthCodeCreateResult {

        let api = try requireApi()
        
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
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Error in result"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkAuthCodeCreateArgs()
            args.durationMinutes = 5
            args.uses = 1

            api.authCodeCreate(args, callback: callback)
            
        }
    }
    
    func authCodeLogin(_ args: SdkAuthCodeLoginArgs) async throws -> SdkAuthCodeLoginResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = AuthCodeLoginCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No result found in callback"]))
                    return
                }
                
                if result.error != nil {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "Error in result"]))
                    return
                    
                }

                guard !result.jwt.isEmpty else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "authCodeLogin returned empty JWT"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            api.authCodeLogin(args, callback: callback)
            
        }
    }

    func authWalletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = AuthWalletChallengeCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No result found in callback"]))
                    return
                }

                if let resultError = result.error {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: resultError.message]))
                    return
                }

                continuation.resume(returning: result)

            }

            api.authWalletChallenge(args, callback: callback)

        }
    }
    
}

// MARK - referral code
extension UrApiService {
    
    func validateReferralCode(_ code: String) async throws -> SdkValidateReferralCodeResult {
        let api = try requireApi()
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
        
        let api = try requireApi()
        
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
    
    func redeemBalanceCode(_ code: String) async throws -> SdkRedeemBalanceCodeResult {
        
        let api = try requireApi()
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = RedeemBalanceCodeCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "RedeemBalanceCodeCallback result is nil"]))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            let args = SdkRedeemBalanceCodeArgs()
            args.secret = code
            
            api.redeemBalanceCode(args, callback: callback)
        }
        
    }
    
    func getRedeemedBalanceCodes() async throws -> SdkGetNetworkRedeemedBalanceCodesResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = GetNetworkRedeemedBalanceCodesCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NSError(domain: "UrApiService", code: 0, userInfo: [NSLocalizedDescriptionKey: "GetNetworkRedeemedBalanceCodesCallback result is nil"]))
                    return
                }

                if let resultError = result.error {
                    continuation.resume(throwing: UrApiError.resultError(message: resultError.message))
                    return
                }
                
                continuation.resume(returning: result)
                
            }
            
            api.getNetworkRedeemedBalanceCodes(callback)
        }
    }
    
}

// MARK - blocking locations
extension UrApiService {
    
    func blockLocation(_ locationId: SdkId) async throws -> SdkNetworkBlockLocationResult {
        
        let api = try requireApi()
        
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
        
        let api = try requireApi()
        
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
        
        let api = try requireApi()
        
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
        
        let api = try requireApi()
        
        return try await withCheckedThrowingContinuation { continuation in
            
            let callback = NetworkDeleteCallback { result, err in
                
                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }
                
                guard let result = result else {
                    continuation.resume(throwing: NetworkDeleteError.resultInvalid)
                    return
                }

                continuation.resume(returning: result)

            }

            api.networkDelete(callback)
            
        }
        
    }
    
    func getReferralNetwork() async throws -> SdkGetReferralNetworkResult {
        
        let api = try requireApi()
        
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
        
        let api = try requireApi()
        
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
        let api = try requireApi()
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
        
        let api = try requireApi()
        
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
        
        let api = try requireApi()
        
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

private class AuthWalletChallengeCallback: SdkCallback<SdkAuthWalletChallengeResult, SdkAuthWalletChallengeCallbackProtocol>, SdkAuthWalletChallengeCallbackProtocol {
    func result(_ result: SdkAuthWalletChallengeResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ValidateReferralCallback: SdkCallback<SdkValidateReferralCodeResult, SdkValidateReferralCodeCallbackProtocol>, SdkValidateReferralCodeCallbackProtocol {
    func result(_ result: SdkValidateReferralCodeResult?, err: Error?) {
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

private class RedeemBalanceCodeCallback: SdkCallback<SdkRedeemBalanceCodeResult, SdkRedeemBalanceCodeCallbackProtocol>, SdkRedeemBalanceCodeCallbackProtocol {
    func result(_ result: SdkRedeemBalanceCodeResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetNetworkRedeemedBalanceCodesCallback: SdkCallback<SdkGetNetworkRedeemedBalanceCodesResult, SdkGetNetworkRedeemedBalanceCodesCallbackProtocol>, SdkGetNetworkRedeemedBalanceCodesCallbackProtocol {
    func result(_ result: SdkGetNetworkRedeemedBalanceCodesResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class AuthCodeLoginCallback: SdkCallback<SdkAuthCodeLoginResult, SdkAuthCodeLoginCallbackProtocol>, SdkAuthCodeLoginCallbackProtocol {
    func result(_ result: SdkAuthCodeLoginResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

/**
 * Error enums
 */

// general errors
enum UrApiError: LocalizedError {
    case resultEmpty
    case resultError(message: String)

    var errorDescription: String? {
        switch self {
        case .resultEmpty:
            return "Result was empty."
        case .resultError(let message):
            return message
        }
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

// MARK: device

extension UrApiService {

    func getNetworkClients() async throws -> SdkNetworkClientsResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in

            let callback = GetNetworkClientsCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: DeviceInfoError.resultEmpty)
                    return
                }

                continuation.resume(returning: result)
            }

            api.getNetworkClients(callback)

        }
    }

    func deviceSetName(deviceId: SdkId, deviceName: String) async throws -> Void {
        let api = try requireApi()
        let _: SdkDeviceSetNameResult = try await withCheckedThrowingContinuation { continuation in

            let args = SdkDeviceSetNameArgs()
            args.deviceId = deviceId
            args.deviceName = deviceName

            let callback = DeviceSetNameCallback { result, err in

                if let err = err {
                    continuation.resume(throwing: err)
                    return
                }

                if let resultError = result?.error {
                    continuation.resume(throwing: DeviceInfoError.resultError(message: resultError.message))
                    return
                }

                guard let result = result else {
                    continuation.resume(throwing: DeviceInfoError.resultEmpty)
                    return
                }

                continuation.resume(returning: result)
            }

            api.deviceSetName(args, callback: callback)

        }
    }

}

private class GetNetworkClientsCallback: SdkCallback<
    SdkNetworkClientsResult, SdkGetNetworkClientsCallbackProtocol
>, SdkGetNetworkClientsCallbackProtocol
{
    func result(_ result: SdkNetworkClientsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class DeviceSetNameCallback: SdkCallback<
    SdkDeviceSetNameResult, SdkDeviceSetNameCallbackProtocol
>, SdkDeviceSetNameCallbackProtocol
{
    func result(_ result: SdkDeviceSetNameResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

// MARK: — Account Management Callbacks

private class GenerateSeedphraseCallback: SdkCallback<SdkGenerateSeedphraseResult, SdkGenerateSeedphraseCallbackProtocol>, SdkGenerateSeedphraseCallbackProtocol {
    func result(_ result: SdkGenerateSeedphraseResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class RegenerateSeedphraseCallback: SdkCallback<SdkRegenerateSeedphraseResult, SdkRegenerateSeedphraseCallbackProtocol>, SdkRegenerateSeedphraseCallbackProtocol {
    func result(_ result: SdkRegenerateSeedphraseResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class AddAuthCallback: SdkCallback<SdkAddAuthResult, SdkAddAuthCallbackProtocol>, SdkAddAuthCallbackProtocol {
    func result(_ result: SdkAddAuthResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class RemoveAuthCallback: SdkCallback<SdkRemoveAuthResult, SdkRemoveAuthCallbackProtocol>, SdkRemoveAuthCallbackProtocol {
    func result(_ result: SdkRemoveAuthResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ChangeNetworkNameCallback: SdkCallback<SdkChangeNetworkNameResult, SdkChangeNetworkNameCallbackProtocol>, SdkChangeNetworkNameCallbackProtocol {
    func result(_ result: SdkChangeNetworkNameResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ClaimNetworkNameCallback: SdkCallback<SdkClaimNetworkNameResult, SdkClaimNetworkNameCallbackProtocol>, SdkClaimNetworkNameCallbackProtocol {
    func result(_ result: SdkClaimNetworkNameResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum DeviceInfoError: Error {
    case resultEmpty
    case resultError(message: String)
}
