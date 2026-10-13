//
//  NetworkConsentClient.swift
//  URnetwork
//
//  The network payout consent's door to the SDK: the network's consent, the
//  server-issued challenge a coldkey signs, and the signed consent's
//  submission (POST /sn/wallet without a client id). One signature covers
//  every provider client of the network, so the SDK asks with the network
//  credential, and only the network's owner can. The SDK picks the epoch
//  range: from the next epoch, until the network changes it.
//

import Foundation
import URnetworkSdk

/// The network's payout consent, from the SDK's SnNetworkConsentStatus.
struct NetworkConsentStatusInfo: Equatable {
    /// a consent is in force, or starts next epoch
    let active: Bool
    let coldkeySs58: String
    let fromEpoch: Int64
    let throughEpoch: Int64
}

protocol NetworkConsentClient: AnyObject {
    func status() async throws -> NetworkConsentStatusInfo
    /// the challenge for the coldkey: the exact message to sign, its range
    /// and its expiry
    func challenge(coldkeySs58: String) async throws -> SdkSnNetworkConsentChallengeResult
    /// the signed message; a signature that does not verify for the coldkey
    /// throws EarningsClientError.signatureMismatch
    func submit(coldkeySs58: String, message: String, signature: String) async throws
}

/// The SDK-backed client.
final class NetworkConsentSdkClient: NetworkConsentClient {

    private let api: SdkApi?

    init(api: SdkApi?) {
        self.api = api
    }

    private func requireApi() throws -> SdkApi {
        guard let api else {
            throw EarningsClientError.sdkUnavailable
        }
        return api
    }

    /// A POST /sn/wallet refusal as a client error (nil for none). The
    /// signature mismatch keeps its own case; any other reads "code:
    /// message", or the code or the message alone.
    static func error(_ setError: SdkSnSetWalletError?) -> EarningsClientError? {
        guard let setError else {
            return nil
        }
        if setError.code == EarningsClientError.signatureMismatchCode {
            return .signatureMismatch(setError.message)
        }
        if setError.code.isEmpty {
            return .message(setError.message)
        }
        if setError.message.isEmpty {
            return .message(setError.code)
        }
        return .message("\(setError.code): \(setError.message)")
    }

    func status() async throws -> NetworkConsentStatusInfo {
        let api = try requireApi()
        let result: SdkSnNetworkConsentStatus = try await withCheckedThrowingContinuation { continuation in
            let callback = SnNetworkConsentStatusCallback { result, err in
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
            api.snNetworkConsentStatus(callback)
        }
        return NetworkConsentStatusInfo(
            active: result.active,
            coldkeySs58: result.coldkeySs58,
            fromEpoch: result.fromEpoch,
            throughEpoch: result.throughEpoch
        )
    }

    func challenge(coldkeySs58: String) async throws -> SdkSnNetworkConsentChallengeResult {
        let api = try requireApi()
        return try await withCheckedThrowingContinuation { continuation in
            let callback = SnNetworkConsentChallengeCallback { result, err in
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
            api.snNetworkConsentChallenge(coldkeySs58, callback: callback)
        }
    }

    func submit(coldkeySs58: String, message: String, signature: String) async throws {
        let api = try requireApi()
        let result: SdkSnSetWalletResult = try await withCheckedThrowingContinuation { continuation in
            let callback = SnSetWalletCallback { result, err in
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
            api.snNetworkConsentSubmit(coldkeySs58, message: message, signatureHex: signature, callback: callback)
        }
        if let error = Self.error(result.error) {
            throw error
        }
    }
}

// MARK: SDK callback bridges

private class SnNetworkConsentStatusCallback: SdkCallback<SdkSnNetworkConsentStatus, SdkSnNetworkConsentStatusCallbackProtocol>, SdkSnNetworkConsentStatusCallbackProtocol {
    func result(_ result: SdkSnNetworkConsentStatus?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnNetworkConsentChallengeCallback: SdkCallback<SdkSnNetworkConsentChallengeResult, SdkSnNetworkConsentChallengeCallbackProtocol>, SdkSnNetworkConsentChallengeCallbackProtocol {
    func result(_ result: SdkSnNetworkConsentChallengeResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

private class SnSetWalletCallback: SdkCallback<SdkSnSetWalletResult, SdkSnSetWalletCallbackProtocol>, SdkSnSetWalletCallbackProtocol {
    func result(_ result: SdkSnSetWalletResult?, err: Error?) {
        handleResult(result, err: err)
    }
}

/// Canned consent for previews.
final class NetworkConsentPreviewClient: NetworkConsentClient {

    var consent: NetworkConsentStatusInfo

    init(consent: NetworkConsentStatusInfo = NetworkConsentStatusInfo(active: false, coldkeySs58: "", fromEpoch: 0, throughEpoch: 0)) {
        self.consent = consent
    }

    func status() async throws -> NetworkConsentStatusInfo { consent }
    func challenge(coldkeySs58: String) async throws -> SdkSnNetworkConsentChallengeResult {
        let result = SdkSnNetworkConsentChallengeResult()
        result.message = "Approve URnetwork network wallet mapping\n{\"scope\":\"network\"}"
        result.coldkeySs58 = coldkeySs58
        result.expiresAt = Int64(Date().timeIntervalSince1970) + 300
        return result
    }
    func submit(coldkeySs58: String, message: String, signature: String) async throws {
        consent = NetworkConsentStatusInfo(active: true, coldkeySs58: coldkeySs58, fromEpoch: 43, throughEpoch: 43 + 65535)
    }
}
