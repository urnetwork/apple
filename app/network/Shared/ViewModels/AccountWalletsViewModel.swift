//
//  WalletsViewModel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/15.
//

import Foundation
import URnetworkSdk

private class TransferStatsCallback: SdkCallback<SdkTransferStatsResult, SdkGetTransferStatsCallbackProtocol>, SdkGetTransferStatsCallbackProtocol {
    func result(_ result: SdkTransferStatsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetAccountWalletsCallback: SdkCallback<SdkGetAccountWalletsResult, SdkGetAccountWalletsCallbackProtocol>, SdkGetAccountWalletsCallbackProtocol {
    func result(_ result: SdkGetAccountWalletsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class RemoveWalletCallback: SdkCallback<SdkRemoveWalletResult, SdkRemoveWalletCallbackProtocol>, SdkRemoveWalletCallbackProtocol {
    func result(_ result: SdkRemoveWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum RemoveWalletError: Error {
    case isLoading
    case noWalletId
}

@MainActor
class AccountWalletsViewModel: ObservableObject {
    
    let domain = "[AccountWalletsViewModel]"
    @Published private(set) var wallets: [SdkAccountWallet] = []
    @Published private(set) var isLoadingTransferStats: Bool = false
    @Published private(set) var isLoadingAccountWallets: Bool = false
    @Published private(set) var isCreatingExternalWallet: Bool = false
    @Published private(set) var isRemovingWallet: Bool = false
    
    /**
     * For removing wallet
     */
    @Published var isPresentingRemoveWalletSheet: Bool = false
    @Published var queuedToRemove: SdkId?
    
    @Published private(set) var unpaidMegaBytes: String = ""
    
    /**
     * For connecting a new wallet
     */
    @Published var isCreatingWallet: Bool = false
    
    /**
     * Saga / Seeker token holder
     */
    @Published private(set) var isVerifyingSeekerOrSagaOwnership: Bool = false
    @Published private(set) var isSeekerOrSagaHolder: Bool = false
    
    var api: SdkApi?
    
    init(api: SdkApi?) {
        self.api = api
        self.initAccountWallets()
        self.initTransferStats()
    }
    
    func initAccountWallets() {
        Task {
            await fetchAccountWallets()
        }
    }
    
    func fetchAccountWallets() async {
        
        if isLoadingAccountWallets {
            return
        }
        
        isLoadingAccountWallets = true
            
        do {
            let result: SdkGetAccountWalletsResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = GetAccountWalletsCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkGetAccountWalletsResult result is nil"]))
                        return
                    }
                    
                    continuation.resume(returning: result)
                    
                }
                
                api?.getAccountWallets(callback)
            }
            
            wallets = handleAccountWalletsList(result)
            isLoadingAccountWallets = false
            
        } catch(let error) {
            print("\(domain) Error fetching account wallets: \(error)")
            isLoadingAccountWallets = false
        }
        
    }
    
    private func handleAccountWalletsList(_ result: SdkGetAccountWalletsResult) -> [SdkAccountWallet] {

        guard let walletsList = result.wallets else { return [] }
        
        var accountWallets: [SdkAccountWallet] = []
        let n = walletsList.len()
        
        for i in 0..<n {
            let wallet = walletsList.get(i)
            
            if let wallet = wallet {
                accountWallets.append(wallet)
                
                if (wallet.hasSeekerToken && !self.isSeekerOrSagaHolder) {
                    self.isSeekerOrSagaHolder = true
                }
                
            }
        }
        
        return accountWallets
        
    }
    
    func initTransferStats() {
        Task {
            await fetchTransferStats()
        }
    }
    
    /**
     * Fetch unpaid bytes provided
     */
    func fetchTransferStats() async {
        
        if isLoadingTransferStats {
            return
        }
        
        isLoadingTransferStats = true
        
        do {
            
            let result: SdkTransferStatsResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = TransferStatsCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "TransferStatsCallback result is nil"]))
                        return
                    }
                    
                    continuation.resume(returning: result)
                }
                
                api?.getTransferStats(callback)
                
            }
            
            let unpaidBytes = result.unpaidBytesProvided
            
            if unpaidBytes >= 1_000_000_000 { // 1 GB = 1,000,000,000 bytes
                let unpaidGigaBytes = unpaidBytes / 1_000_000_000
                unpaidMegaBytes = String(format: "%.2f GB", unpaidGigaBytes)
            } else {
                let unpaidMegaBytesValue = unpaidBytes / 1_000_000
                unpaidMegaBytes = String(format: "%.2f MB", unpaidMegaBytesValue)
            }
            
            isLoadingTransferStats = false
            
        } catch(let error) {
            print("\(domain) Error fetching transfer stats: \(error)")
            isLoadingTransferStats = false
        }
            
    }
    
}

// MARK: remove wallet
extension AccountWalletsViewModel {
    
    func promptRemoveWallet(_ walletId: SdkId) {
        isPresentingRemoveWalletSheet = true
        queuedToRemove = walletId
    }
    
    func removeWallet() async -> Result<Void, Error> {

        if isRemovingWallet {
            return .failure(RemoveWalletError.isLoading)
        }
        
        guard let walletId = queuedToRemove else {
            return .failure(RemoveWalletError.noWalletId)
        }
        
        isRemovingWallet = true
        
        do {
            let _: SdkRemoveWalletResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = RemoveWalletCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkRemoveWalletResult result is nil"]))
                        return
                    }
                    
                    continuation.resume(returning: result)
                }
                
                let args = SdkRemoveWalletArgs()
                args.walletId = walletId.idStr
                
                api?.removeWallet(args, callback: callback)
                
            }
            
            await fetchAccountWallets()
            isRemovingWallet = false
            
            return .success(())
        } catch(let error) {
            isRemovingWallet = false
            print("\(domain) error removing wallet: \(error)")
            return .failure(error)
        }
        
    }
}


// MARK: connect wallet
extension AccountWalletsViewModel {
    
    func connectWallet(walletAddress: String, chain: WalletChain) async -> Result<Void, Error> {
        
        if isCreatingWallet {
            return .failure(CreateWalletError.isLoading)
        }
        
        if chain == .invalid {
            return .failure(CreateWalletError.invalidChain)
        }
        
        isCreatingWallet = true
        
        do {
            
            let result: SdkCreateAccountWalletResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = CreateAccountWalletCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: NSError(domain: self.domain, code: 0, userInfo: [NSLocalizedDescriptionKey: "SdkCreateAccountWalletResult result is nil"]))
                        return
                    }
                    
                    continuation.resume(returning: result)
                }
                
                let args = SdkCreateAccountWalletArgs()
                args.blockchain = chain.rawValue
                args.walletAddress = walletAddress
                
                api?.createAccountWallet(args, callback: callback)
            }
            
            isCreatingWallet = false
            await self.fetchAccountWallets()
            return .success(())
            
        } catch(let error) {
            isCreatingWallet = false
            return .failure(error)
        }
        
    }
    
}

// MARK: verify Seeker/Saga ownership
extension AccountWalletsViewModel {
    
    func verifySeekerOrSagaOwnership(
        publicKey: String,
        message: String,
        signature: String,
    ) async -> Result<Bool, Error> {
     
        if (isVerifyingSeekerOrSagaOwnership) {
            return .failure(SeekerSagaVerificationError.alreadyProcessing)
        }
        
        isVerifyingSeekerOrSagaOwnership = true
        
        do {
            
            let result: SdkVerifySeekerNftHolderResult = try await withCheckedThrowingContinuation { [weak self] continuation in
                
                guard let self = self else { return }
                
                let callback = VerifySeekerNftHolderCallback { result, err in
                    
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    
                    guard let result = result else {
                        continuation.resume(throwing: SeekerSagaVerificationError.invalidResult)
                        return
                    }
                    
                    continuation.resume(returning: result)
                }
                
                let args = SdkVerifySeekerNftHolderArgs()
                args.publicKey = publicKey
                args.signature = signature
                args.message = message
                
                
                api?.verifySeekerHolder(args, callback: callback)
            }
            
            isVerifyingSeekerOrSagaOwnership = false
            
            await self.fetchAccountWallets()
            
            return .success(result.success)
            
        } catch(let error) {
            isVerifyingSeekerOrSagaOwnership = false
            return .failure(error)
        }
        
        
    }
    
}

private class VerifySeekerNftHolderCallback: SdkCallback<SdkVerifySeekerNftHolderResult, SdkVerifySeekerNftHolderCallbackProtocol>, SdkVerifySeekerNftHolderCallbackProtocol {
    func result(_ result: SdkVerifySeekerNftHolderResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class CreateAccountWalletCallback: SdkCallback<SdkCreateAccountWalletResult, SdkCreateAccountWalletCallbackProtocol>, SdkCreateAccountWalletCallbackProtocol {
    func result(_ result: SdkCreateAccountWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class ValidateAddressCallback: SdkCallback<SdkWalletValidateAddressResult, SdkWalletValidateAddressCallbackProtocol>, SdkWalletValidateAddressCallbackProtocol {
    func result(_ result: SdkWalletValidateAddressResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

enum CreateWalletError: Error {
    case isLoading
    case invalidResult
    case invalidChain
    case invalidAddress
}

enum SeekerSagaVerificationError: Error {
    case alreadyProcessing
    case invalidResult
    case invalidSignature
    case unknown(String)
}
