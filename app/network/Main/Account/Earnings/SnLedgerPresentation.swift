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
//  From capture the flag (sn/CAPTURETHEFLAG.md §10) a coldkey can hold an
//  account in the operator's capture the flag pool beside its pool account.
//  Each shows as its own row, named "Capture the flag" and "Provider pool"; a
//  pool the operator could not read just now says so in its row without
//  hiding the others; and one claim claims both. Entries from a server that
//  predates it have no kind and show as before.
//

import Foundation

/// The latest settlement v2 ledger read.
enum SnLedgerLoad: Equatable {
    /// nothing read yet
    case loading
    /// the latest read failed (ledger_unavailable, or any other error): the
    /// balances are unavailable, never zero
    case unavailable
    /// the coldkey's accounts, one per pool, empty when the ledger has none;
    /// and the pools the operator could not read just now
    case loaded([SnLedgerAccountInfo], unavailablePools: [SnLedgerUnavailablePool] = [])

    var accounts: [SnLedgerAccountInfo] {
        if case .loaded(let accounts, _) = self {
            return accounts
        }
        return []
    }

    var unavailablePools: [SnLedgerUnavailablePool] {
        if case .loaded(_, let unavailablePools) = self {
            return unavailablePools
        }
        return []
    }
}

/// What a pool's row is called, from its kind (the sdk's Label is the
/// server's English name, which the app does not show). Before capture the
/// flag a row is "Pool 1", as it has been. A capture the flag account is
/// "Capture the flag", and the operator's pool beside one is the "Provider
/// pool".
enum SnLedgerPoolName: Equatable {
    /// "Pool %lld"
    case pool(noId: Int64)
    case providerPool
    case captureTheFlag

    /// `besideCtf`: the rows include a capture the flag pool, read or not
    static func of(kind: SnLedgerPoolKind, noId: Int64, besideCtf: Bool) -> SnLedgerPoolName {
        switch kind {
        case .ctf:
            return .captureTheFlag
        case .pool:
            return besideCtf ? .providerPool : .pool(noId: noId)
        }
    }

    /// the name every pool had before capture the flag, which a lone pool's
    /// row leaves out
    var isPoolNumber: Bool {
        if case .pool = self {
            return true
        }
        return false
    }

    /// The name in the app's language. `bundle` is the catalog to read (nil:
    /// the app's).
    func text(bundle: Bundle? = nil) -> String {
        switch self {
        case .pool(let noId):
            return String(localized: "Pool \(noId)", bundle: bundle)
        case .providerPool:
            return String(localized: "Provider pool", bundle: bundle)
        case .captureTheFlag:
            return String(localized: "Capture the flag", bundle: bundle)
        }
    }
}

/// The rules of a ledger's rows that look across its pools: what each row is
/// called, and which capture the flag balance is under the transfer floor.
struct SnLedgerPools: Equatable {

    let accounts: [SnLedgerAccountInfo]
    let unavailablePools: [SnLedgerUnavailablePool]
    /// the relay's transfer floor in rao of α (SnClaimStatusInfo.transferFloorRao),
    /// 0 when it gave none
    var transferFloorRao: Int64 = 0

    /// the ledger lists a capture the flag pool, read or not
    var besideCtf: Bool {
        accounts.contains { $0.kind == .ctf } || unavailablePools.contains { $0.kind == .ctf }
    }

    func name(_ account: SnLedgerAccountInfo) -> SnLedgerPoolName {
        SnLedgerPoolName.of(kind: account.kind, noId: account.noId, besideCtf: besideCtf)
    }

    func name(_ pool: SnLedgerUnavailablePool) -> SnLedgerPoolName {
        SnLedgerPoolName.of(kind: pool.kind, noId: pool.noId, besideCtf: besideCtf)
    }

    /// A capture the flag balance the chain cannot move yet: under the
    /// transfer floor at the relay's last price, which URnetwork's claim leaves
    /// waiting too (one slot is often less). A pool account keeps the rule it
    /// had: its claim's preflight decides.
    static func underFloor(kind: SnLedgerPoolKind, claimableRao: Int64, transferFloorRao: Int64) -> Bool {
        kind == .ctf && 0 < claimableRao && claimableRao < transferFloorRao
    }

    func underFloor(_ account: SnLedgerAccountInfo) -> Bool {
        Self.underFloor(kind: account.kind, claimableRao: account.claimableRao, transferFloorRao: transferFloorRao)
    }

    /// what a claim pays: something to claim, and not under the floor
    func claimable(_ account: SnLedgerAccountInfo) -> Bool {
        0 < account.claimableRao && !underFloor(account)
    }

    /// The claim claims a pool account and a capture the flag account
    /// together, and its button says "Claim both".
    func claimsBoth(_ claimable: [SnLedgerAccountInfo]) -> Bool {
        claimable.count == 2 && claimable.contains { $0.kind == .pool } && claimable.contains { $0.kind == .ctf }
    }

    /// the tile's rows: each account, then each pool that could not be read
    var rows: [SnLedgerPoolRow] {
        accounts.map { SnLedgerPoolRow(name: name($0), balance: .account($0), underFloor: underFloor($0)) }
            + unavailablePools.map { SnLedgerPoolRow(name: name($0), balance: .unavailable($0)) }
    }
}

/// One pool's row on the Settlement v2 tile: its name, and the account's
/// balances, or "Unavailable right now" in their place for a pool the
/// operator could not read just now.
struct SnLedgerPoolRow: Identifiable, Equatable {

    enum Balance: Equatable {
        case account(SnLedgerAccountInfo)
        case unavailable(SnLedgerUnavailablePool)
    }

    let name: SnLedgerPoolName
    let balance: Balance
    /// "Below the claim minimum": a capture the flag balance under the
    /// transfer floor (SnLedgerPools.underFloor)
    var underFloor: Bool = false

    var id: String {
        switch balance {
        case .account(let account):
            return "\(account.vault)/\(account.noId)/\(account.index)"
        case .unavailable(let pool):
            return "\(pool.vault)/\(pool.noId)"
        }
    }
}

/// What the Settlement v2 tile shows.
struct SnLedgerTilePresentation: Equatable {

    enum Balances: Equatable {
        /// "Unavailable" in place of the amounts
        case unavailable
        /// each pool's row
        case pools([SnLedgerPoolRow])
        /// what the claim relay says is claimable, for a network with no
        /// wallet on this device to read the ledger by, and a row for each
        /// pool it could not read, which the amount leaves out
        case claimable(Int64, unavailablePools: [SnLedgerPoolRow] = [])
    }

    let balances: Balances
    /// the Claim action shows: v2 claims are configured
    let showsClaim: Bool
    /// and can be used: something is claimable and no v2 claim runs
    let claimEnabled: Bool
    /// each row names its pool: there is more than one, or one that is not
    /// the operator's pool
    let showsPools: Bool
    /// Claim says "Claim both": it claims a pool account and a capture the
    /// flag account together
    var claimsBoth: Bool = false

    /// The tile, or nil for none: nothing read yet, no account, or a ledger
    /// that cannot be read before v2 claims are configured (before
    /// activation balances show only when the ledger returns some). A pool
    /// that could not be read is a row of its own and hides no other.
    static func of(
        load: SnLedgerLoad,
        claimConfigured: Bool,
        isClaiming: Bool,
        transferFloorRao: Int64 = 0
    ) -> SnLedgerTilePresentation? {
        switch load {
        case .loading:
            return nil
        case .unavailable:
            guard claimConfigured else {
                return nil
            }
            return SnLedgerTilePresentation(balances: .unavailable, showsClaim: true, claimEnabled: false, showsPools: false)
        case .loaded(let accounts, let unavailablePools):
            // a pool that could not be read is no balance to show before
            // activation, as a ledger that could not be read is none
            guard !accounts.isEmpty || (claimConfigured && !unavailablePools.isEmpty) else {
                return nil
            }
            let pools = SnLedgerPools(accounts: accounts, unavailablePools: unavailablePools, transferFloorRao: transferFloorRao)
            let rows = pools.rows
            let claimable = accounts.filter(pools.claimable)
            return SnLedgerTilePresentation(
                balances: .pools(rows),
                showsClaim: claimConfigured,
                claimEnabled: claimConfigured && !isClaiming && !claimable.isEmpty,
                showsPools: rows.count > 1 || rows.contains { !$0.name.isPoolNumber },
                claimsBoth: pools.claimsBoth(claimable)
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
    /// "Below the claim minimum": no claim can move it yet
    case underFloor
    /// "Unavailable right now", in place of the amount: the pool could not be
    /// read, by the ledger read or by the claim
    case unavailable
}

/// One pool's line in the v2 claim sheet: the live claim progress while a
/// claim runs, else what the ledger says. A pool that could not be read is a
/// line of its own, which hides no other.
struct SnLedgerClaimRow: Identifiable, Equatable {
    let id: SnLedgerAccountKey
    let name: SnLedgerPoolName
    /// the transfer the vault confirmed once the claim lands, else what is
    /// claimable
    let amountRao: Int64
    let status: SnLedgerClaimStatus
    /// the claim transaction on the explorer, once sent
    let explorerUrl: URL?

    /// a pool the ledger read could not read, under the key the claim
    /// reports it by
    static func of(_ pool: SnLedgerUnavailablePool, pools: SnLedgerPools) -> SnLedgerClaimRow {
        SnLedgerClaimRow(id: pool.id, name: pools.name(pool), amountRao: 0, status: .unavailable, explorerUrl: nil)
    }

    /// `pools`: the ledger the account is in, which names it and gives the
    /// floor (nil: the account alone, with no floor)
    static func of(
        _ account: SnLedgerAccountInfo,
        progress: EarningsViewModel.LedgerClaimRowState?,
        chain: SnLedgerChainInfo,
        pools: SnLedgerPools? = nil
    ) -> SnLedgerClaimRow {
        let pools = pools ?? SnLedgerPools(accounts: [account], unavailablePools: [])
        let name = pools.name(account)
        func row(_ amountRao: Int64, _ status: SnLedgerClaimStatus, _ explorerUrl: URL? = nil) -> SnLedgerClaimRow {
            SnLedgerClaimRow(id: account.id, name: name, amountRao: amountRao, status: status, explorerUrl: explorerUrl)
        }
        guard let progress else {
            if pools.underFloor(account) {
                return row(account.claimableRao, .underFloor)
            }
            if account.claimableRao > 0 {
                return row(account.claimableRao, .unclaimed)
            }
            return row(account.claimableRao, account.paidRao > 0 ? .claimed : .pending)
        }
        switch progress {
        case .queued:
            return row(account.claimableRao, .pending)
        case .sent(let txHash):
            return row(account.claimableRao, .sent, chain.explorerUrl(txHash: txHash))
        case .confirmed(let txHash, let amountRao):
            return row(amountRao, .claimed, chain.explorerUrl(txHash: txHash))
        case .alreadyClaimed:
            return row(account.claimableRao, .claimed)
        case .failed:
            return row(account.claimableRao, .failed)
        case .unavailable:
            return row(account.claimableRao, .unavailable)
        }
    }
}

/// One of the relay's rows in its claim sheet, as Android draws them
/// (snClaimRelayRows): each account with something to claim, Pending, or
/// "Below the claim minimum" for a capture the flag balance under the
/// transfer floor; each URnetwork claimed with nothing claimable since,
/// Claimed with its transaction; then each pool that could not be read. A
/// network paid to more than one coldkey names each row's.
struct SnClaimRelayRow: Identifiable, Equatable {

    enum Status: Equatable {
        case pending
        case underFloor
        case claimed
        case unavailable
    }

    let id: String
    let name: SnLedgerPoolName
    /// the account's coldkey where the rows span more than one, else ""
    let coldkeySs58: String
    /// what it holds to claim, or what URnetwork's claim paid; 0 for a pool
    /// that could not be read
    let amountRao: Int64
    let status: Status
    /// URnetwork's claim on the explorer, for a Claimed row
    let txUrl: URL?

    /// The rows of the relay's answer, or none without capture the flag: a
    /// relay that lists no capture the flag pool and no pool it could not
    /// read keeps the sheet's one balance, as it has been.
    static func rows(_ status: SnClaimStatusInfo) -> [SnClaimRelayRow] {
        guard status.besideCtf || !status.unavailablePools.isEmpty else {
            return []
        }
        let accounts = status.accounts.filter { 0 < $0.claimableRao || $0.showsClaimed }
        let coldkeys = Set(accounts.map(\.coldkeySs58))
        let rows = accounts.map { account in
            let underFloor = SnLedgerPools.underFloor(
                kind: account.kind,
                claimableRao: account.claimableRao,
                transferFloorRao: status.transferFloorRao
            )
            let state: Status = account.showsClaimed ? .claimed : underFloor ? .underFloor : .pending
            return SnClaimRelayRow(
                id: "\(account.coldkeySs58)/\(account.noId)",
                name: SnLedgerPoolName.of(kind: account.kind, noId: account.noId, besideCtf: status.besideCtf),
                coldkeySs58: 1 < coldkeys.count ? account.coldkeySs58 : "",
                amountRao: account.showsClaimed ? account.claimAmountRao : account.claimableRao,
                status: state,
                txUrl: account.showsClaimed && !account.claimTxUrl.isEmpty ? URL(string: account.claimTxUrl) : nil
            )
        }
        return rows + status.unavailablePools.map { pool in
            SnClaimRelayRow(
                id: "\(pool.vault)/\(pool.noId)",
                name: SnLedgerPoolName.of(kind: pool.kind, noId: pool.noId, besideCtf: status.besideCtf),
                coldkeySs58: "",
                amountRao: 0,
                status: .unavailable,
                txUrl: nil
            )
        }
    }
}

extension SnClaimStatusInfo {

    /// the relay lists a capture the flag pool, read or not
    var besideCtf: Bool {
        accounts.contains { $0.kind == .ctf } || unavailablePools.contains { $0.kind == .ctf }
    }

    /// the tile's rows of the pools the relay could not read, which its total
    /// leaves out
    var unavailablePoolRows: [SnLedgerPoolRow] {
        unavailablePools.map { pool in
            SnLedgerPoolRow(
                name: SnLedgerPoolName.of(kind: pool.kind, noId: pool.noId, besideCtf: besideCtf),
                balance: .unavailable(pool)
            )
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

    /// the SDK's ledger_unavailable (SnErrorCodeLedgerUnavailable): naming a
    /// pool with index 0, the claim could not read that pool and claimed the
    /// others, so the pool is unavailable right now, not a failure
    static let ledgerUnavailableCode = "ledger_unavailable"

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
