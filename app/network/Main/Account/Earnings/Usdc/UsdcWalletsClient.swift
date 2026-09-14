//
//  UsdcWalletsClient.swift
//  URnetwork
//
//  The legacy USDC payout wallet's door to the API: check a Solana address,
//  link it, read the account's wallets, the payout wallet and the payments,
//  select or remove a wallet. The SDK callback bridges are the ones the Payout
//  Wallets screen used before the Earnings screen replaced it (93da20e^).
//

import Foundation
import URnetworkSdk

protocol UsdcWalletsClient: AnyObject {
    /// `POST /wallet/validate-address` with chain SOL
    func validateSolanaAddress(_ address: String) async throws -> Bool
    /// `POST /account/wallet` with blockchain SOL; returns the new wallet's id.
    /// The server makes it the payout wallet when the network has none.
    func addSolanaWallet(address: String) async throws -> String
    /// the account's active USDC wallets (`GET /account/wallets`)
    func wallets() async throws -> [UsdcWalletInfo]
    /// `GET /account/payout-wallet`; nil when the network has none
    func payoutWalletId() async throws -> String?
    /// `POST /account/payout-wallet`
    func setPayoutWallet(id: String) async throws
    /// `POST /account/wallets/remove`
    func removeWallet(id: String) async throws
    /// `GET /account/payments`: every payment of the network that is not
    /// canceled, pending ones included
    func payments() async throws -> [UsdcPaymentInfo]
}

/// The SDK-backed client.
final class UsdcWalletsSdkClient: UsdcWalletsClient {

    private let api: SdkApi?
    private let urApiService: UrApiServiceProtocol

    init(api: SdkApi?, urApiService: UrApiServiceProtocol) {
        self.api = api
        self.urApiService = urApiService
    }

    private func requireApi() throws -> SdkApi {
        guard let api else {
            throw UsdcWalletsClientError.sdkUnavailable
        }
        return api
    }

    func validateSolanaAddress(_ address: String) async throws -> Bool {
        try await urApiService.validateWalletAddress(address: address, chain: SdkSOL)
    }

    func addSolanaWallet(address: String) async throws -> String {
        let api = try requireApi()
        let result: SdkCreateAccountWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = CreateAccountWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: UsdcWalletsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            let args = SdkCreateAccountWalletArgs()
            args.blockchain = SdkSOL
            args.walletAddress = address
            args.defaultTokenType = "USDC"
            api.createAccountWallet(args, callback: callback)
        }
        guard let walletId = result.walletId?.idStr, !walletId.isEmpty else {
            throw UsdcWalletsClientError.emptyResult
        }
        return walletId
    }

    func wallets() async throws -> [UsdcWalletInfo] {
        let api = try requireApi()
        let result: SdkGetAccountWalletsResult = try await withCheckedThrowingContinuation { continuation in
            let callback = GetAccountWalletsCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: UsdcWalletsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            api.getAccountWallets(callback)
        }
        return Self.usdcWallets(from: result.wallets)
    }

    func payoutWalletId() async throws -> String? {
        let api = try requireApi()
        let result: SdkGetPayoutWalletIdResult = try await withCheckedThrowingContinuation { continuation in
            let callback = FetchPayoutWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: UsdcWalletsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            api.getPayoutWallet(callback)
        }
        guard let walletId = result.walletId?.idStr, !walletId.isEmpty else {
            return nil
        }
        return walletId
    }

    func setPayoutWallet(id: String) async throws {
        let api = try requireApi()
        var parseError: NSError?
        guard let walletId = SdkParseId(id, &parseError) else {
            if let parseError {
                throw parseError
            }
            throw UsdcWalletsClientError.message("Invalid wallet id")
        }
        let _: SdkSetPayoutWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = UpdatePayoutWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: UsdcWalletsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            let args = SdkSetPayoutWalletArgs()
            args.walletId = walletId
            api.setPayoutWallet(args, callback: callback)
        }
    }

    func removeWallet(id: String) async throws {
        let api = try requireApi()
        let result: SdkRemoveWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = RemoveWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: UsdcWalletsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            let args = SdkRemoveWalletArgs()
            args.walletId = id
            api.removeWallet(args, callback: callback)
        }
        if let resultError = result.error {
            // the server's reason is the detail; a refusal without one has none
            throw resultError.message.isEmpty
                ? UsdcWalletsClientError.emptyResult
                : UsdcWalletsClientError.message(resultError.message)
        }
        guard result.success else {
            throw UsdcWalletsClientError.emptyResult
        }
    }

    func payments() async throws -> [UsdcPaymentInfo] {
        let api = try requireApi()
        let result: SdkGetNetworkAccountPaymentsResult = try await withCheckedThrowingContinuation { continuation in
            let callback = GetAccountPaymentsCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: UsdcWalletsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            api.getAccountPayments(callback)
        }
        if let resultError = result.error {
            throw UsdcWalletsClientError.message(resultError.message)
        }
        return Self.payments(from: result.accountPayments)
    }

    // MARK: mapping

    /// The active USDC wallets: SOL and legacy MATIC rows that are not Circle
    /// custodial wallets. TAO rows are Bittensor wallets and never receive
    /// USDC.
    static func usdcWallets(from list: SdkAccountWalletsList?) -> [UsdcWalletInfo] {
        guard let list else {
            return []
        }
        var wallets: [UsdcWalletInfo] = []
        for i in 0..<list.len() {
            guard let wallet = list.get(i),
                  wallet.active,
                  wallet.circleWalletId.isEmpty,
                  let chain = UsdcChain(rawValue: wallet.blockchain.uppercased()),
                  let walletId = wallet.walletId?.idStr,
                  !walletId.isEmpty else {
                continue
            }
            wallets.append(UsdcWalletInfo(
                id: walletId,
                chain: chain,
                address: wallet.walletAddress,
                hasSeekerToken: wallet.hasSeekerToken
            ))
        }
        return wallets
    }

    static func payments(from list: SdkAccountPaymentsList?) -> [UsdcPaymentInfo] {
        guard let list else {
            return []
        }
        var payments: [UsdcPaymentInfo] = []
        for i in 0..<list.len() {
            guard let payment = list.get(i) else {
                continue
            }
            payments.append(UsdcPaymentInfo(
                id: payment.paymentId?.idStr ?? "payment-\(i)",
                walletId: payment.walletId?.idStr,
                payoutNanoCents: payment.payout,
                tokenAmount: payment.tokenAmount,
                completed: payment.completed,
                canceled: payment.canceled,
                completeTimeMillis: payment.completeTime?.unixMilli()
            ))
        }
        return payments
    }
}

// MARK: SDK callback bridges

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

private class CreateAccountWalletCallback: SdkCallback<SdkCreateAccountWalletResult, SdkCreateAccountWalletCallbackProtocol>, SdkCreateAccountWalletCallbackProtocol {
    func result(_ result: SdkCreateAccountWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class FetchPayoutWalletCallback: SdkCallback<SdkGetPayoutWalletIdResult, SdkGetPayoutWalletCallbackProtocol>, SdkGetPayoutWalletCallbackProtocol {
    func result(_ result: SdkGetPayoutWalletIdResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class UpdatePayoutWalletCallback: SdkCallback<SdkSetPayoutWalletResult, SdkSetPayoutWalletCallbackProtocol>, SdkSetPayoutWalletCallbackProtocol {
    func result(_ result: SdkSetPayoutWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class GetAccountPaymentsCallback: SdkCallback<SdkGetNetworkAccountPaymentsResult, SdkGetAccountPaymentsCallbackProtocol>, SdkGetAccountPaymentsCallbackProtocol {
    func result(_ result: SdkGetNetworkAccountPaymentsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

/// Canned data for previews.
final class UsdcWalletsPreviewClient: UsdcWalletsClient {

    static let sampleAddress = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"

    private var walletRows: [UsdcWalletInfo]
    private var payoutId: String?
    private let paymentRows: [UsdcPaymentInfo]

    init(startLinked: Bool = false, pendingUsdNanoCents: Int64 = 0) {
        let wallet = UsdcWalletInfo(
            id: "preview-wallet",
            chain: .sol,
            address: UsdcWalletsPreviewClient.sampleAddress,
            hasSeekerToken: false
        )
        walletRows = startLinked ? [wallet] : []
        payoutId = startLinked ? wallet.id : nil
        paymentRows = pendingUsdNanoCents > 0 ? [
            UsdcPaymentInfo(
                id: "preview-payment",
                walletId: nil,
                payoutNanoCents: pendingUsdNanoCents,
                tokenAmount: 0,
                completed: false,
                canceled: false,
                completeTimeMillis: nil
            )
        ] : []
    }

    func validateSolanaAddress(_ address: String) async throws -> Bool {
        (32...44).contains(address.count)
    }

    func addSolanaWallet(address: String) async throws -> String {
        let wallet = UsdcWalletInfo(
            id: "preview-wallet-\(walletRows.count + 1)",
            chain: .sol,
            address: address,
            hasSeekerToken: false
        )
        walletRows.append(wallet)
        if payoutId == nil {
            payoutId = wallet.id
        }
        return wallet.id
    }

    func wallets() async throws -> [UsdcWalletInfo] {
        walletRows
    }

    func payoutWalletId() async throws -> String? {
        payoutId
    }

    func setPayoutWallet(id: String) async throws {
        payoutId = id
    }

    func removeWallet(id: String) async throws {
        walletRows.removeAll { $0.id == id }
        if payoutId == id {
            payoutId = nil
        }
    }

    func payments() async throws -> [UsdcPaymentInfo] {
        paymentRows
    }
}
