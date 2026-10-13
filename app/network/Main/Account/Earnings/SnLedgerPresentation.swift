//
//  SnLedgerPresentation.swift
//  URnetwork
//
//  Settlement v2 on the Earnings screen, beside the v1 claims, which stay as
//  they are: what the v2 tile shows, each pool's line in the v2 claim sheet
//  and how a failed v2 claim reads. A ledger that cannot be read is
//  "Unavailable", never 0; a pending root is pending; the v2 Claim shows
//  only once v2 claims are configured (STSettlementVault2 pinned in the SDK's
//  chain settings).
//

import Foundation

/// The latest settlement v2 ledger read.
enum SnLedgerLoad: Equatable {
    /// nothing read yet
    case loading
    /// the latest read failed (ledger_unavailable, or any other error): the
    /// balances are unavailable, never zero
    case unavailable
    /// the coldkey's accounts, one per pool; empty when the ledger has none
    case loaded([SnLedgerAccountInfo])

    var accounts: [SnLedgerAccountInfo] {
        if case .loaded(let accounts) = self {
            return accounts
        }
        return []
    }
}

/// What the Settlement v2 tile shows.
struct SnLedgerTilePresentation: Equatable {

    enum Balances: Equatable {
        /// "Unavailable" in place of the amounts
        case unavailable
        case accounts([SnLedgerAccountInfo])
    }

    let balances: Balances
    /// the Claim action shows: v2 claims are configured
    let showsClaim: Bool
    /// and can be used: something is claimable and no v2 claim runs
    let claimEnabled: Bool
    /// each account names its pool: there is more than one
    let showsPools: Bool

    /// The tile, or nil for none: nothing read yet, no account, or a ledger
    /// that cannot be read before v2 claims are configured (before
    /// activation balances show only when the ledger returns some).
    static func of(load: SnLedgerLoad, claimConfigured: Bool, isClaiming: Bool) -> SnLedgerTilePresentation? {
        switch load {
        case .loading:
            return nil
        case .unavailable:
            guard claimConfigured else {
                return nil
            }
            return SnLedgerTilePresentation(balances: .unavailable, showsClaim: true, claimEnabled: false, showsPools: false)
        case .loaded(let accounts):
            guard !accounts.isEmpty else {
                return nil
            }
            return SnLedgerTilePresentation(
                balances: .accounts(accounts),
                showsClaim: claimConfigured,
                claimEnabled: claimConfigured && !isClaiming && accounts.contains { $0.claimableRao > 0 },
                showsPools: accounts.count > 1
            )
        }
    }
}

/// The state pill of one pool's line in the v2 claim sheet.
enum SnLedgerClaimStatus: Equatable {
    case unclaimed
    case pending
    case sent
    case claimed
    case failed
}

/// One pool's line in the v2 claim sheet: the live claim progress while a
/// claim runs, else what the ledger says.
struct SnLedgerClaimRow: Identifiable, Equatable {
    let id: SnLedgerAccountKey
    /// the transfer the vault confirmed once the claim lands, else what is
    /// claimable
    let amountRao: Int64
    let status: SnLedgerClaimStatus
    /// the claim transaction on the explorer, once sent
    let explorerUrl: URL?

    static func of(
        _ account: SnLedgerAccountInfo,
        progress: EarningsViewModel.LedgerClaimRowState?,
        chain: SnLedgerChainInfo
    ) -> SnLedgerClaimRow {
        guard let progress else {
            let status: SnLedgerClaimStatus
            if account.claimableRao > 0 {
                status = .unclaimed
            } else {
                status = account.paidRao > 0 ? .claimed : .pending
            }
            return SnLedgerClaimRow(id: account.id, amountRao: account.claimableRao, status: status, explorerUrl: nil)
        }
        switch progress {
        case .queued:
            return SnLedgerClaimRow(id: account.id, amountRao: account.claimableRao, status: .pending, explorerUrl: nil)
        case .sent(let txHash):
            return SnLedgerClaimRow(id: account.id, amountRao: account.claimableRao, status: .sent, explorerUrl: chain.explorerUrl(txHash: txHash))
        case .confirmed(let txHash, let amountRao):
            return SnLedgerClaimRow(id: account.id, amountRao: amountRao, status: .claimed, explorerUrl: chain.explorerUrl(txHash: txHash))
        case .alreadyClaimed:
            return SnLedgerClaimRow(id: account.id, amountRao: account.claimableRao, status: .claimed, explorerUrl: nil)
        case .failed:
            return SnLedgerClaimRow(id: account.id, amountRao: account.claimableRao, status: .failed, explorerUrl: nil)
        }
    }
}

/// How a failed v2 claim reads. The SDK's message starts with an SnErrorCode*
/// value, then ": " and the detail; the code picks the wording the v1 claim
/// already uses, and any other refusal shows as the SDK wrote it.
enum SnLedgerClaimFailure: Equatable {
    /// needs_gas: the gas key cannot cover the claim; the gas card shows the
    /// top-up
    case needsGas
    /// the chain, or the operator's ledger, could not be reached
    case unreachable
    /// no coldkey is connected, or this device's state is unavailable
    case connectWallet
    /// proof_mismatch, not_claimable, claim_failed and the rest, as sent
    case message(String)

    /// the SDK's already_claimed (SnErrorCodeAlreadyClaimed): another sender
    /// claimed the account first, which is success, not a failure
    static let alreadyClaimedCode = "already_claimed"

    /// the SnErrorCode* a message starts with
    static func code(of message: String) -> String {
        message.components(separatedBy: ": ").first?.trimmingCharacters(in: .whitespaces) ?? message
    }

    static func of(_ message: String) -> SnLedgerClaimFailure {
        switch code(of: message) {
        case "needs_gas":
            return .needsGas
        case "chain_rpc_unreachable", "chain_not_configured", "ledger_unavailable", "artifact_unavailable":
            return .unreachable
        case "connect_wallet_first", "local_state_unavailable":
            return .connectWallet
        default:
            return .message(message)
        }
    }
}
