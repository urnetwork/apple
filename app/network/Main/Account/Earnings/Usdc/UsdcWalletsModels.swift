//
//  UsdcWalletsModels.swift
//  URnetwork
//
//  Plain models for the legacy USDC payout wallet on the Earnings screen.
//  USDC payouts go to a Solana wallet (older accounts may still have a Polygon
//  one) until the migration to Bittensor is complete. They mirror the SDK's
//  account wallet and payment shapes so the views never hold gomobile objects.
//

import Foundation

/// The chains a USDC payout wallet is on. Anything else, TAO included, is not
/// a USDC wallet.
enum UsdcChain: String {
    case sol = "SOL"
    /// legacy Polygon wallets from older versions
    case matic = "MATIC"
}

/// An active USDC wallet of the account.
struct UsdcWalletInfo: Identifiable, Equatable {
    /// the wallet id (`SdkId.idStr`)
    let id: String
    let chain: UsdcChain
    let address: String
    let hasSeekerToken: Bool
}

/// A payment of the network. It is pending until it completes or is canceled.
struct UsdcPaymentInfo: Identifiable, Equatable {
    let id: String
    let walletId: String?
    /// `payout_nano_cents`
    let payoutNanoCents: Int64
    let tokenAmount: Double
    let completed: Bool
    let canceled: Bool
    let completeTimeMillis: Int64?

    var isPending: Bool {
        !completed && !canceled
    }
}

enum UsdcFormat {

    /// "3.87". The server's `NanoCentsToUsd` divides by 1e9.
    static func usd(nanoCents: Int64) -> String {
        String(format: "%.2f", Double(nanoCents) / 1_000_000_000)
    }
}

enum UsdcWalletsClientError: LocalizedError, Equatable {
    /// no SDK api (signed out, or a preview)
    case sdkUnavailable
    case emptyResult
    case message(String)

    var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "API not available"
        case .emptyResult:
            return "The server returned no result"
        case .message(let message):
            return message
        }
    }
}
