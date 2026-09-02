//
//  EarningsModels.swift
//  URnetwork
//
//  Plain models for the points-first Earnings screen: the account's points
//  per finalized epoch, the connected Bittensor coldkey, the SDK-held gas key,
//  the settlement-vault claims and the Top 200 head-spot status. They mirror
//  the SDK's sn* shapes so the views never hold gomobile objects.
//

import Foundation

/// The coldkey alpha settles to. Attached to this device's provider client.
struct SnWalletInfo: Equatable {
    let coldkeySs58: String
    let clientId: String
    let setAtMillis: Int64
}

/// The SDK-generated EVM key that pays claim gas. The secret never leaves the
/// SDK; the app only sees the address and the ss58 mirror to fund it.
struct SnGasKeyInfo: Equatable {
    let address: String
    let mirrorSs58: String
}

enum SnClaimStatus: String {
    case open
    case claimable
    case claimed
    case expired
    case notFinalized = "not-finalized"

    init(sdkStatus: String) {
        self = SnClaimStatus(rawValue: sdkStatus) ?? .open
    }
}

/// One finalized epoch's entitlement in the settlement vault.
struct SnEpochClaimInfo: Identifiable, Equatable {
    let epoch: Int64
    let shareBps: Int64
    let amountRao: Int64
    var status: SnClaimStatus
    let claimOpenBlock: Int64
    let expiryBlock: Int64
    var txHash: String

    var id: Int64 { epoch }
}

/// One finalized epoch of the account's points history.
struct AccountEpochInfo: Identifiable, Equatable {
    let epoch: Int64
    let startMillis: Int64
    let endMillis: Int64
    let points: Double
    let shareBps: Int64

    var id: Int64 { epoch }
}

/// Head-miner (Top 200) status of the network.
struct SnHeadInfo: Equatable {
    let eligible: Bool
    let score: Double
    let floor: Double
    let rankEstimate: Int64
    let cutoff: Int64
    let bound: Bool
    let hotkey: String
    let uid: Int64
    let rank: Int64
    let epoch: Int64
    let source: String

    /// bound, with a score within 15% of the eviction floor
    var nearEvictionFloor: Bool {
        bound && floor > 0 && score < floor * 1.15
    }
}

/// The unauthenticated wallet check every address goes through before it is
/// sent anywhere.
struct SnWalletValidation: Equatable {
    let validSyntax: Bool
    let existsOnChain: Bool
    let banned: Bool
    let message: String
}

/// Progress of a direct claim: the SDK signs and sends each epoch's claim
/// from the gas key and reports here.
enum SnClaimEvent {
    case sent(epoch: Int64, txHash: String)
    case confirmed(epoch: Int64, txHash: String, amountRao: Int64)
    case failed(epoch: Int64, message: String)
    case done
}

enum EarningsClientError: LocalizedError, Equatable {
    /// the SDK build in use has no subnet surface yet
    case sdkUnavailable
    case noWallet
    case emptyResult
    case message(String)

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "The chain RPC is unreachable. Try again."
        case .noWallet:
            return "Connect a Bittensor wallet first."
        case .emptyResult:
            return "The chain RPC is unreachable. Try again."
        case .message(let message):
            return message
        }
    }
}
