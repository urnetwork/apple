//
//  EarningsClient.swift
//  URnetwork
//
//  The Earnings screen's door to the SDK: the account's epoch history, the
//  Bittensor wallet attached to this device's provider client, the gas key,
//  the settlement-vault claims and the Top 200 head status. Claims are direct
//  between the SDK on this device and the vault contract; nothing here goes
//  through a URnetwork API at claim time.
//

import Foundation
import URnetworkSdk

final class EarningsSubscription {
    private let onCancel: () -> Void

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }

    deinit {
        onCancel()
    }
}

protocol EarningsClient: AnyObject {

    // utilities
    func validateSs58(_ address: String) -> Bool
    func shortSs58(_ address: String) -> String
    func formatAlpha(rao: Int64) -> String
    func formatShareBps(_ shareBps: Int64) -> String

    // wallet
    /// the message the ur.io wallet bridge signs to prove the coldkey (purpose "connect")
    func walletChallenge(address: String?) async throws -> String
    /// unauthenticated check; runs before the address is sent anywhere else
    func validateWallet(_ address: String) async throws -> SnWalletValidation
    func cachedWallet() -> SnWalletInfo?
    func fetchWallet() async throws -> SnWalletInfo?
    func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo
    func observeWallet(_ onChange: @escaping (SnWalletInfo?) -> Void) -> EarningsSubscription

    // gas key and claims
    /// stores the vault and coordinator addresses from the server's epoch
    /// endpoint; claims report "chain_not_configured" until this has run once
    func syncChainSettings() async throws
    func gasKey() -> SnGasKeyInfo?
    func gasBalanceTao() async throws -> Double
    func claims() async throws -> (claims: [SnEpochClaimInfo], totalClaimableRao: Int64)
    func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void)

    // points history and head spot
    func accountEpochs() async throws -> [AccountEpochInfo]
    func head() async throws -> SnHeadInfo?
}

/// The SDK-backed client. The device methods run in this process (they need
/// local state, the api and the chain, not the tunnel), so they work whether
/// or not the extension is up.
final class EarningsSdkClient: EarningsClient {

    private let api: SdkApi?
    private let urApiService: UrApiServiceProtocol
    private let device: SdkDeviceRemote?

    init(api: SdkApi?, urApiService: UrApiServiceProtocol, device: SdkDeviceRemote?) {
        self.api = api
        self.urApiService = urApiService
        self.device = device
    }

    private func requireApi() throws -> SdkApi {
        guard let api else {
            throw EarningsClientError.sdkUnavailable
        }
        return api
    }

    private func requireDevice() throws -> SdkDeviceRemote {
        guard let device else {
            throw EarningsClientError.sdkUnavailable
        }
        return device
    }

    private static func error(_ snError: SdkSnError?) -> EarningsClientError? {
        guard let snError else {
            return nil
        }
        if snError.message.isEmpty {
            return .message(snError.code)
        }
        return .message("\(snError.code): \(snError.message)")
    }

    private static func wallet(from sdkWallet: SdkSnWallet) -> SnWalletInfo {
        SnWalletInfo(
            coldkeySs58: sdkWallet.coldkeySs58,
            clientId: sdkWallet.clientId,
            setAtMillis: sdkWallet.setAtMillis
        )
    }

    // MARK: utilities

    func validateSs58(_ address: String) -> Bool {
        SdkValidateSs58(address)
    }

    func shortSs58(_ address: String) -> String {
        SdkShortSs58(address)
    }

    func formatAlpha(rao: Int64) -> String {
        SdkFormatAlpha(rao)
    }

    func formatShareBps(_ shareBps: Int64) -> String {
        SdkFormatShareBps(shareBps)
    }

    // MARK: wallet

    func walletChallenge(address: String?) async throws -> String {
        let args = SdkAuthWalletChallengeArgs()
        args.blockchain = "bittensor"
        if let address, !address.isEmpty {
            args.walletAddress = address
        }
        let result = try await urApiService.authWalletChallenge(args)
        guard !result.messageTemplate.isEmpty else {
            throw EarningsClientError.emptyResult
        }
        return result.messageTemplate
    }

    func validateWallet(_ address: String) async throws -> SnWalletValidation {
        let api = try requireApi()
        let result: SdkSnValidateWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnValidateWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            api.snValidateWallet(address, callback: callback)
        }
        return SnWalletValidation(
            validSyntax: result.validSyntax,
            existsOnChain: result.existsOnChain,
            banned: result.banned,
            message: result.message
        )
    }

    func cachedWallet() -> SnWalletInfo? {
        guard let sdkWallet = device?.getSnWallet(), !sdkWallet.coldkeySs58.isEmpty else {
            return nil
        }
        return Self.wallet(from: sdkWallet)
    }

    func fetchWallet() async throws -> SnWalletInfo? {
        let device = try requireDevice()
        let result: SdkSnGetWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnGetWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            // refreshes the device's wallet cache from the server as well
            device.syncSnWallet(callback)
        }
        guard let sdkWallet = result.wallet, !sdkWallet.coldkeySs58.isEmpty else {
            return nil
        }
        return Self.wallet(from: sdkWallet)
    }

    func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo {
        let device = try requireDevice()
        let result: SdkSnConnectWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnConnectWalletCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            device.connectSnWallet(coldkeySs58, signature: signature, message: message, callback: callback)
        }
        guard let sdkWallet = result.wallet, !sdkWallet.coldkeySs58.isEmpty else {
            throw EarningsClientError.emptyResult
        }
        return Self.wallet(from: sdkWallet)
    }

    func observeWallet(_ onChange: @escaping (SnWalletInfo?) -> Void) -> EarningsSubscription {
        guard let device else {
            return EarningsSubscription {}
        }
        let listener = SnWalletChangeListener { sdkWallet in
            if let sdkWallet, !sdkWallet.coldkeySs58.isEmpty {
                onChange(Self.wallet(from: sdkWallet))
            } else {
                onChange(nil)
            }
        }
        let sub = device.add(listener)
        return EarningsSubscription {
            sub?.close()
            // keeps the listener alive for the life of the subscription
            _ = listener
        }
    }

    // MARK: gas key and claims

    func syncChainSettings() async throws {
        let device = try requireDevice()
        let _: SdkSnEpochResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnEpochCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                continuation.resume(returning: result)
            }
            device.syncSnChainSettings(callback)
        }
    }

    func gasKey() -> SnGasKeyInfo? {
        guard let key = device?.getSnGasKey(), !key.address.isEmpty else {
            return nil
        }
        return SnGasKeyInfo(address: key.address, mirrorSs58: key.mirrorSs58)
    }

    func gasBalanceTao() async throws -> Double {
        let device = try requireDevice()
        let result: SdkSnGasBalanceResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnGasBalanceCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            device.snGasBalance(callback)
        }
        return result.tao
    }

    func claims() async throws -> (claims: [SnEpochClaimInfo], totalClaimableRao: Int64) {
        let device = try requireDevice()
        let result: SdkSnClaimsResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnClaimsCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            device.snClaims(callback)
        }
        var claims: [SnEpochClaimInfo] = []
        if let list = result.claims {
            for i in 0..<list.len() {
                guard let claim = list.get(i) else { continue }
                claims.append(SnEpochClaimInfo(
                    epoch: claim.epoch,
                    shareBps: claim.shareBps,
                    amountRao: claim.amountRao,
                    status: SnClaimStatus(sdkStatus: claim.status),
                    claimOpenBlock: claim.claimOpenBlock,
                    expiryBlock: claim.expiryBlock,
                    txHash: claim.txHash
                ))
            }
        }
        return (claims, result.totalClaimableRao)
    }

    func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void) {
        guard let device, let list = SdkInt64List() else {
            for epoch in epochs {
                onEvent(.failed(epoch: epoch, message: "local_state_unavailable"))
            }
            onEvent(.done)
            return
        }
        for epoch in epochs {
            list.add(epoch)
        }
        device.snClaim(list, callback: SnClaimCallbackBridge(onEvent))
    }

    // MARK: points history and head spot

    func accountEpochs() async throws -> [AccountEpochInfo] {
        let api = try requireApi()
        let result: SdkAccountEpochsResult = try await withCheckedThrowingContinuation { continuation in
            let callback = AccountEpochsCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            api.accountEpochs(callback)
        }
        var epochs: [AccountEpochInfo] = []
        if let list = result.epochs {
            for i in 0..<list.len() {
                guard let epoch = list.get(i) else { continue }
                epochs.append(AccountEpochInfo(
                    epoch: epoch.epoch,
                    startMillis: epoch.startMillis,
                    endMillis: epoch.endMillis,
                    points: epoch.points,
                    shareBps: epoch.shareBps
                ))
            }
        }
        return epochs
    }

    func head() async throws -> SnHeadInfo? {
        let api = try requireApi()
        let result: SdkSnHeadResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnHeadCallback { result, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: EarningsClientError.emptyResult)
                    return
                }
                if let error = Self.error(result.error) {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: result)
            }
            api.snHead(callback)
        }
        return SnHeadInfo(
            eligible: result.eligible,
            score: result.score,
            floor: result.floor,
            rankEstimate: result.rankEstimate,
            cutoff: result.cutoff,
            bound: result.bound,
            hotkey: result.hotkey,
            uid: result.uid,
            rank: result.rank,
            epoch: result.epoch,
            source: result.source
        )
    }
}

// MARK: SDK callback bridges

private class SnValidateWalletCallback: SdkCallback<SdkSnValidateWalletResult, SdkSnValidateWalletCallbackProtocol>, SdkSnValidateWalletCallbackProtocol {
    func result(_ result: SdkSnValidateWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnGetWalletCallback: SdkCallback<SdkSnGetWalletResult, SdkSnGetWalletCallbackProtocol>, SdkSnGetWalletCallbackProtocol {
    func result(_ result: SdkSnGetWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnConnectWalletCallback: SdkCallback<SdkSnConnectWalletResult, SdkSnConnectWalletCallbackProtocol>, SdkSnConnectWalletCallbackProtocol {
    func result(_ result: SdkSnConnectWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnEpochCallback: SdkCallback<SdkSnEpochResult, SdkSnEpochCallbackProtocol>, SdkSnEpochCallbackProtocol {
    func result(_ result: SdkSnEpochResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnGasBalanceCallback: SdkCallback<SdkSnGasBalanceResult, SdkSnGasBalanceCallbackProtocol>, SdkSnGasBalanceCallbackProtocol {
    func result(_ result: SdkSnGasBalanceResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnClaimsCallback: SdkCallback<SdkSnClaimsResult, SdkSnClaimsCallbackProtocol>, SdkSnClaimsCallbackProtocol {
    func result(_ result: SdkSnClaimsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class AccountEpochsCallback: SdkCallback<SdkAccountEpochsResult, SdkAccountEpochsCallbackProtocol>, SdkAccountEpochsCallbackProtocol {
    func result(_ result: SdkAccountEpochsResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnHeadCallback: SdkCallback<SdkSnHeadResult, SdkSnHeadCallbackProtocol>, SdkSnHeadCallbackProtocol {
    func result(_ result: SdkSnHeadResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

/// The SDK reports each epoch's claim as it is sent and confirmed.
private final class SnClaimCallbackBridge: NSObject, SdkSnClaimCallbackProtocol {

    private let onEvent: (SnClaimEvent) -> Void

    init(_ onEvent: @escaping (SnClaimEvent) -> Void) {
        self.onEvent = onEvent
    }

    func sent(_ epoch: Int64, txHash: String?) {
        onEvent(.sent(epoch: epoch, txHash: txHash ?? ""))
    }

    func confirmed(_ epoch: Int64, txHash: String?, amountRao: Int64) {
        onEvent(.confirmed(epoch: epoch, txHash: txHash ?? "", amountRao: amountRao))
    }

    func failed(_ epoch: Int64, message: String?) {
        onEvent(.failed(epoch: epoch, message: message ?? "claim_failed"))
    }

    func done() {
        onEvent(.done)
    }
}

private final class SnWalletChangeListener: NSObject, SdkSnWalletChangeListenerProtocol {

    private let onChange: (SdkSnWallet?) -> Void

    init(_ onChange: @escaping (SdkSnWallet?) -> Void) {
        self.onChange = onChange
    }

    func snWalletChanged(_ wallet: SdkSnWallet?) {
        onChange(wallet)
    }
}

/// Canned data for previews.
final class EarningsPreviewClient: EarningsClient {

    var wallet: SnWalletInfo?
    var headInfo: SnHeadInfo?
    var epochRows: [AccountEpochInfo]
    var claimRows: [SnEpochClaimInfo]
    var gasTao: Double

    init(
        wallet: SnWalletInfo? = nil,
        head: SnHeadInfo? = nil,
        epochs: [AccountEpochInfo] = [],
        claims: [SnEpochClaimInfo] = [],
        gasTao: Double = 0
    ) {
        self.wallet = wallet
        self.headInfo = head
        self.epochRows = epochs
        self.claimRows = claims
        self.gasTao = gasTao
    }

    func validateSs58(_ address: String) -> Bool { SnAlpha.looksLikeSs58(address) }
    func shortSs58(_ address: String) -> String { SnAlpha.shortSs58(address) }
    func formatAlpha(rao: Int64) -> String { SnAlpha.format(rao: rao) }
    func formatShareBps(_ shareBps: Int64) -> String { SnAlpha.formatShareBps(shareBps) }
    func walletChallenge(address: String?) async throws -> String { "connect" }
    func validateWallet(_ address: String) async throws -> SnWalletValidation {
        SnWalletValidation(validSyntax: true, existsOnChain: true, banned: false, message: "")
    }
    func cachedWallet() -> SnWalletInfo? { wallet }
    func fetchWallet() async throws -> SnWalletInfo? { wallet }
    func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo {
        let connected = SnWalletInfo(coldkeySs58: coldkeySs58, clientId: "", setAtMillis: Int64(Date().timeIntervalSince1970 * 1000))
        wallet = connected
        return connected
    }
    func observeWallet(_ onChange: @escaping (SnWalletInfo?) -> Void) -> EarningsSubscription { EarningsSubscription {} }
    func syncChainSettings() async throws {}
    func gasKey() -> SnGasKeyInfo? {
        SnGasKeyInfo(address: "0x1111111111111111111111111111111111111111", mirrorSs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY")
    }
    func gasBalanceTao() async throws -> Double { gasTao }
    func claims() async throws -> (claims: [SnEpochClaimInfo], totalClaimableRao: Int64) {
        (claimRows, claimRows.filter { $0.status == .claimable }.reduce(0) { $0 + $1.amountRao })
    }
    func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void) {
        for epoch in epochs {
            onEvent(.sent(epoch: epoch, txHash: "0xabc"))
            onEvent(.confirmed(epoch: epoch, txHash: "0xabc", amountRao: claimRows.first { $0.epoch == epoch }?.amountRao ?? 0))
        }
        onEvent(.done)
    }
    func accountEpochs() async throws -> [AccountEpochInfo] { epochRows }
    func head() async throws -> SnHeadInfo? { headInfo }
}
