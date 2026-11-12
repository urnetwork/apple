//
//  EarningsViewModel.swift
//  URnetwork
//
//  State of the points-first Earnings screen. Points come from the account
//  points store; this holds the subnet layer, which only carries data once a
//  Bittensor coldkey is attached: the wallet, the epoch history rows, the
//  vault claims, the settlement v2 accounts (the pool's and the capture the
//  flag pool's) and their claim, the gas key balance and the network's Top
//  200 standing on the Protocol leaderboard.
//

import Foundation

@MainActor
final class EarningsViewModel: ObservableObject {

    enum ClaimRowState: Equatable {
        case queued
        case sent(txHash: String)
        case confirmed(txHash: String, amountRao: Int64)
        case failed(message: String)
    }

    /// The claim progress of one settlement v2 account (pool).
    enum LedgerClaimRowState: Equatable {
        case queued
        case sent(txHash: String)
        case confirmed(txHash: String, amountRao: Int64)
        /// another sender claimed it first (already_claimed): done, not a
        /// failure
        case alreadyClaimed
        case failed(message: String)
        /// the gas key could not pay for its claim (needs_gas), so the sdk
        /// sent nothing for it: still claimable, with the gas card's top-up,
        /// and no failure. The sdk claims the largest account first, so with
        /// gas for one claim the others wait here (sdk-ctf-v2 §2.1).
        case needsGas
        /// the sdk's preflight found it under the transfer floor
        /// (not_claimable: AmountTooLow) and sent nothing: it waits, below
        /// the claim minimum, and it is no failure
        case underFloor
        /// the claim could not read the account's pool (ledger_unavailable
        /// naming the pool) and claimed the others: unavailable, not a
        /// failure
        case unavailable

        /// vault2 paid the account: this claim, or another sender's first
        var paid: Bool {
            switch self {
            case .confirmed, .alreadyClaimed:
                return true
            case .queued, .sent, .failed, .needsGas, .underFloor, .unavailable:
                return false
            }
        }
    }

    @Published private(set) var wallet: SnWalletInfo?
    @Published private(set) var epochs: [AccountEpochInfo] = []
    @Published private(set) var claims: [SnEpochClaimInfo] = []
    @Published private(set) var totalClaimableRao: Int64 = 0
    /// the current epoch's schedule from the claims read (the coordinator's
    /// policy); nil until read or when the policy could not be read
    @Published private(set) var schedule: SnEpochScheduleInfo?
    @Published private(set) var gasKey: SnGasKeyInfo?
    @Published private(set) var gasTao: Double?
    /// the network on the Protocol leaderboard (GET /sn/top/me); a failed
    /// read keeps the one shown
    @Published private(set) var top: SnTopMeResultInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var loadedOnce = false
    /// the latest epoch history read failed; with no epochs shown that is
    /// not "No epochs yet"
    @Published private(set) var epochsLoadFailed = false
    /// the latest wallet read failed and no wallet is cached; that is not
    /// "no wallet connected"
    @Published private(set) var walletLoadFailed = false

    @Published private(set) var claimProgress: [Int64: ClaimRowState] = [:]
    @Published private(set) var isClaiming = false

    /// the settlement v2 accounts from the latest ledger read
    @Published private(set) var ledger: SnLedgerLoad = .loading
    /// vault2 and the explorer link from the SDK's chain settings
    @Published private(set) var ledgerChain: SnLedgerChainInfo = .unconfigured
    @Published private(set) var ledgerClaimProgress: [SnLedgerAccountKey: LedgerClaimRowState] = [:]
    @Published private(set) var isLedgerClaiming = false

    /// what URnetwork's claim relay says of the network's v2 balance; nil
    /// until read, or with no sdk to ask
    @Published private(set) var claimStatus: SnClaimStatusInfo?
    /// the claim sheet's Claim now: nil before a tap
    @Published private(set) var claimNowOutcome: SnClaimNowOutcome?
    @Published private(set) var isClaimingNow = false

    /// every capture the flag slot the network's clients won whose award is
    /// not claimed yet, newest first, for a line each under the Settlement v2
    /// balances; none without one, or when they could not be read
    @Published private(set) var ctfWins: [SnCtfWinInfo] = []

    let client: EarningsClient
    private var walletSubscription: EarningsSubscription?
    private var chainSettingsSynced = false
    /// the read of the capture the flag wins, which runs beside the refresh
    /// and never holds it up (the sdk waits up to a minute for the route)
    private var ctfWinsRead: Task<Void, Never>?
    /// a read was asked for while one ran
    private var ctfWinsReadAgain = false

    /// the per-claim gas reserve in TAO, which the top-up asks for and Claim
    /// waits for: the SDK sends a v1 claim only when the gas key holds its
    /// gas limit (the estimate plus a quarter, and at least 2,700,000, below
    /// which the vault defers the payment) times 1.1 × the gas price, about
    /// 0.0149 TAO at 5 gwei
    static let gasTaoPerClaim = 0.02

    /// the same for a v2 claim: the SDK sends it only when the gas key holds
    /// its gas limit (the estimate plus a quarter, about 3.14M on runtime
    /// 475 for about 236k used) times 1.1 × the gas price, about 0.0173 TAO
    /// at 5 gwei
    static let ledgerGasTaoPerClaim = 0.02

    init(client: EarningsClient) {
        self.client = client
        self.wallet = client.cachedWallet()
        self.gasKey = client.gasKey()
        walletSubscription = client.observeWallet { [weak self] wallet in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wallet = wallet
                await self.refreshSubnet()
            }
        }
    }

    var hasWallet: Bool {
        wallet != nil
    }

    var claimableClaims: [SnEpochClaimInfo] {
        claims.filter { $0.status == .claimable }
    }

    var claimByEpoch: [Int64: SnEpochClaimInfo] {
        Dictionary(uniqueKeysWithValues: claims.map { ($0.epoch, $0) })
    }

    var gasNeededTao: Double {
        Self.gasTaoPerClaim * Double(max(1, claimableClaims.count))
    }

    var needsGas: Bool {
        (gasTao ?? 0) < gasNeededTao
    }

    /// what the history section shows (SectionLoad)
    var historyLoad: SectionLoad {
        SectionLoad.of(hasData: !epochs.isEmpty, settled: loadedOnce, failed: epochsLoadFailed)
    }

    /// the Top 200 tile, or nil for none (Top200TilePresentation)
    var top200Tile: Top200TilePresentation? {
        Top200TilePresentation.of(top)
    }

    /// the Settlement v2 tile, or nil for none
    var ledgerTile: SnLedgerTilePresentation? {
        SnLedgerTilePresentation.of(
            load: ledger,
            claimConfigured: ledgerChain.claimConfigured,
            isClaiming: isLedgerClaiming,
            transferFloorRao: ledgerTransferFloorRao
        )
    }

    /// the relay's transfer floor in rao of α, 0 while it gives none
    var ledgerTransferFloorRao: Int64 {
        guard let claimStatus, !claimStatus.unavailable else {
            return 0
        }
        return claimStatus.transferFloorRao
    }

    /// the latest ledger read's pools: their names and the floor
    var ledgerPools: SnLedgerPools {
        SnLedgerPools(accounts: ledger.accounts, unavailablePools: ledger.unavailablePools, transferFloorRao: ledgerTransferFloorRao)
    }

    /// The Settlement v2 tile with the relay: the device's wallet's ledger as
    /// before, or, for a network with no wallet on this device, the balance
    /// the relay claims for its consent, while the sdk says the tile shows
    /// (SnClaimStatusResult.ShowsTile), the one rule every app draws by.
    var ledgerTileWithRelay: SnLedgerTilePresentation? {
        if hasWallet, let ledgerTile {
            return ledgerTile
        }
        guard let claimStatus, claimStatus.showsTile else {
            return nil
        }
        return SnLedgerTilePresentation(
            balances: .claimable(
                claimStatus.knownClaimableRao,
                rows: SnClaimRelayRow.tileRows(claimStatus),
                underFloor: SnClaimRelayRow.tileTotalUnderFloor(claimStatus)
            ),
            showsClaim: false,
            claimEnabled: false,
            showsPools: false
        )
    }

    /// Reads what the relay says, after the wallet and the ledger.
    func refreshClaimStatus() async {
        claimStatus = await client.claimStatus()
    }

    func resetClaimNow() {
        claimNowOutcome = nil
    }

    /// Claim now: URnetwork claims the relay's coldkey now, at most once in
    /// the period, and pays the gas.
    func claimNow() async {
        guard let claimStatus, claimStatus.claimNowAvailable, !isClaimingNow else {
            return
        }
        isClaimingNow = true
        claimNowOutcome = await client.claimNow(coldkeySs58: claimStatus.coldkeySs58)
        isClaimingNow = false
        await refreshClaimStatus()
    }

    /// the v2 accounts a claim pays: every one with something claimable,
    /// but a balance under the transfer floor, which the chain refuses
    var ledgerClaimableAccounts: [SnLedgerAccountInfo] {
        let pools = ledgerPools
        return ledger.accounts.filter(pools.claimable)
    }

    /// the claim claims the pool account and the capture the flag account
    /// together: its button says "Claim both"
    var ledgerClaimsBoth: Bool {
        ledgerPools.claimsBoth(ledgerClaimableAccounts)
    }

    /// what a v2 claim pays in all, saturating rather than trapping on an
    /// absurd ledger answer
    var ledgerClaimableRao: Int64 {
        ledgerClaimableAccounts.reduce(0) { total, account in
            let (sum, overflow) = total.addingReportingOverflow(account.claimableRao)
            return overflow ? Int64.max : sum
        }
    }

    /// One claim's reserve, however many accounts the claim pays: with two or
    /// more the SDK sends one STClaimBatcher transaction, whose limit adds
    /// about 150,000 gas a claim to one claim's 2.6M, and with a gas key that
    /// cannot pay for the batch it claims them one at a time, each within the
    /// reserve, as the sdk's SelfClaimNeedsGas counts one claim. A claim the
    /// gas key cannot pay fails needs_gas, which shows the top-up.
    var ledgerGasNeededTao: Double {
        Self.ledgerGasTaoPerClaim
    }

    /// the gas key cannot cover the v2 claims, or the gas key just could not
    /// pay for an account's claim (needs_gas): the gas card shows the top-up
    var ledgerNeedsGas: Bool {
        (gasTao ?? 0) < ledgerGasNeededTao || ledgerClaimProgress.values.contains(.needsGas)
    }

    /// the v2 claim sheet's Claim
    var ledgerClaimEnabled: Bool {
        ledgerChain.claimConfigured && !ledgerClaimableAccounts.isEmpty && !ledgerNeedsGas && !isLedgerClaiming
    }

    /// the v2 claim sheet has no amount to show, never 0: the ledger could not
    /// be read, or it read no account and could not read a pool
    var ledgerClaimUnavailable: Bool {
        ledger == .unavailable || (ledger.accounts.isEmpty && !ledger.unavailablePools.isEmpty)
    }

    /// How and when the provider is paid, for the foot of the points card;
    /// nil until the wallet read settles (a failed read with no cached wallet
    /// says nothing about the coldkey).
    /// `localKeyPaid`: the network's consent pays the payout key on this
    /// device, a coldkey before the wallet read lists it, so there is no
    /// coldkey left to set.
    func payoutLine(nowMillis: Int64, formatTime: (Int64) -> String, localKeyPaid: Bool = false) -> SnPayoutLine? {
        let hasColdkey = hasWallet || localKeyPaid
        return SnPayoutLine.of(
            walletKnown: loadedOnce && (hasColdkey || !walletLoadFailed),
            hasColdkey: hasColdkey,
            totalClaimableRao: totalClaimableRao,
            schedule: schedule,
            nowMillis: nowMillis,
            formatTime: formatTime
        )
    }

    func refresh() async {
        if isLoading {
            return
        }
        isLoading = true

        // `try?` flattens an optional result, so a failed wallet read would
        // read as "none"; earningsAttempt keeps the failure distinct
        let client = client
        refreshCtfWins()
        async let walletTask = earningsAttempt { try await client.fetchWallet() }
        async let epochsTask = earningsAttempt { try await client.accountEpochs() }
        async let topTask = earningsAttempt { try await client.topMe() }

        let (walletResult, epochsResult, topResult) = await (walletTask, epochsTask, topTask)
        if let walletResult {
            wallet = walletResult
            walletLoadFailed = false
        } else {
            wallet = client.cachedWallet()
            walletLoadFailed = wallet == nil
        }
        if let epochsResult {
            epochs = epochsResult.sorted { $0.epoch > $1.epoch }
            epochsLoadFailed = false
        } else {
            // the epochs already shown stay
            epochsLoadFailed = true
        }
        if let topResult {
            top = topResult
        }

        await refreshSubnet()
        await refreshClaimStatus()

        loadedOnce = true
        isLoading = false
    }

    /// Reads the capture the flag wins beside the refresh, one read at a
    /// time; one asked for during a read runs once it ends, so the lines
    /// follow the latest state.
    private func refreshCtfWins() {
        guard ctfWinsRead == nil else {
            ctfWinsReadAgain = true
            return
        }
        let client = client
        ctfWinsRead = Task { [weak self] in
            let wins = await client.ctfUnclaimedWins()
            guard let self else {
                return
            }
            self.ctfWins = wins
            self.ctfWinsRead = nil
            if self.ctfWinsReadAgain {
                self.ctfWinsReadAgain = false
                self.refreshCtfWins()
            }
        }
    }

    /// The layer that only exists with a wallet: gas key, balance, claims,
    /// the settlement v2 accounts.
    func refreshSubnet() async {
        guard hasWallet else {
            claims = []
            totalClaimableRao = 0
            schedule = nil
            gasTao = nil
            ledger = .loaded([])
            return
        }
        if !chainSettingsSynced {
            // the vault and coordinator addresses come from the server once;
            // retried on the next refresh if it fails
            chainSettingsSynced = (try? await client.syncChainSettings()) != nil
        }
        gasKey = client.gasKey()
        ledgerChain = client.ledgerChain()
        async let balanceTask: Double? = try? client.gasBalanceTao()
        async let claimsTask: (claims: [SnEpochClaimInfo], totalClaimableRao: Int64, schedule: SnEpochScheduleInfo?)? = try? client.claims()
        async let ledgerTask: SnLedgerAccountsInfo? = try? client.ledgerAccounts()
        let (balance, claimsResult, ledgerResult) = await (balanceTask, claimsTask, ledgerTask)
        gasTao = balance
        if let claimsResult {
            claims = claimsResult.claims.sorted { $0.epoch > $1.epoch }
            totalClaimableRao = claimsResult.totalClaimableRao
            schedule = claimsResult.schedule
        }
        // the latest read decides: a failed read is unavailable even after a
        // good one, so no claim is offered on balances that could not be read;
        // a pool that could not be read is unavailable on its own
        if let ledgerResult {
            ledger = .loaded(ledgerResult.accounts, unavailablePools: ledgerResult.unavailablePools)
        } else {
            ledger = .unavailable
        }
    }

    func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo {
        let connected = try await client.connectWallet(
            coldkeySs58: coldkeySs58,
            signature: signature,
            message: message
        )
        wallet = connected
        await refreshSubnet()
        return connected
    }

    // MARK: claims

    func claimAll() {
        claim(epochs: claimableClaims.map { $0.epoch })
    }

    func claim(epochs: [Int64]) {
        guard !isClaiming, !epochs.isEmpty else {
            return
        }
        isClaiming = true
        claimProgress = Dictionary(uniqueKeysWithValues: epochs.map { ($0, ClaimRowState.queued) })
        client.claim(epochs: epochs) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.apply(event)
            }
        }
    }

    func resetClaimProgress() {
        claimProgress = [:]
    }

    var claimFailureMessages: [(epoch: Int64, message: String)] {
        claimProgress.compactMap { epoch, state in
            if case .failed(let message) = state {
                return (epoch, message)
            }
            return nil
        }
        .sorted { $0.epoch > $1.epoch }
    }

    var claimFinished: Bool {
        !isClaiming && !claimProgress.isEmpty
    }

    private func apply(_ event: SnClaimEvent) {
        switch event {
        case .sent(let epoch, let txHash):
            claimProgress[epoch] = .sent(txHash: txHash)
        case .confirmed(let epoch, let txHash, let amountRao):
            claimProgress[epoch] = .confirmed(txHash: txHash, amountRao: amountRao)
        case .failed(let epoch, let message):
            claimProgress[epoch] = .failed(message: message)
        case .done:
            isClaiming = false
            Task { [weak self] in
                await self?.refreshSubnet()
            }
        }
    }

    // MARK: settlement v2 claims

    /// Claims every v2 account with something claimable, the pool's and the
    /// capture the flag pool's alike: the SDK sends one claim to
    /// STSettlementVault2 from the gas key, or, for two or more, one
    /// STClaimBatcher transaction that claims them all.
    func claimLedger() {
        let accounts = ledgerClaimableAccounts
        guard !isLedgerClaiming, ledgerChain.claimConfigured, !accounts.isEmpty else {
            return
        }
        isLedgerClaiming = true
        ledgerClaimProgress = Dictionary(accounts.map { ($0.id, LedgerClaimRowState.queued) }, uniquingKeysWith: { first, _ in first })
        client.ledgerClaim { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyLedger(event)
            }
        }
    }

    func resetLedgerClaimProgress() {
        ledgerClaimProgress = [:]
    }

    /// Each account's line in the v2 claim sheet, then each pool that could
    /// not be read. What the claim reports beyond them follows, as Android's,
    /// Linux's and Windows' claim rows do: an account its own read found in a
    /// pool the sheet's read could not read takes that pool's line, and a pool
    /// it could not read that the sheet's read did not list gets a line.
    var ledgerClaimRows: [SnLedgerClaimRow] {
        let listed = Set(ledger.accounts.map(\.id))
        let listedNoIds = Set(ledger.accounts.map(\.noId))
        let unavailableNoIds = Set(ledger.unavailablePools.map(\.noId))
        let extra = ledgerClaimProgress
            .filter { key, state in
                key.noId != 0 && !listed.contains(key)
                    && (state != .unavailable || !(listedNoIds.contains(key.noId) || unavailableNoIds.contains(key.noId)))
            }
            .sorted { ($0.key.noId, $0.key.index) < ($1.key.noId, $1.key.index) }
            .map { key, state in
                (key: key, state: state, kind: ledger.unavailablePools.first { $0.noId == key.noId }?.kind ?? SnLedgerPoolKind(noId: key.noId))
            }
        // every pool in view names the rows: the read's, and any pool the
        // claim reports beyond them
        let reported = extra.filter { !listedNoIds.contains($0.key.noId) && !unavailableNoIds.contains($0.key.noId) }
            .map { SnLedgerUnavailablePool(vault: "", noId: $0.key.noId, kind: $0.kind) }
        let pools = SnLedgerPools(
            accounts: ledger.accounts,
            unavailablePools: ledger.unavailablePools + reported,
            transferFloorRao: ledgerTransferFloorRao
        )
        let extraRows = extra.map { SnLedgerClaimRow.found($0.key, kind: $0.kind, progress: $0.state, chain: ledgerChain, pools: pools) }
        let unavailableRows = ledger.unavailablePools.flatMap { pool in
            let taken = extraRows.filter { $0.id.noId == pool.noId }
            return taken.isEmpty ? [SnLedgerClaimRow.of(pool, pools: pools)] : taken
        }
        return ledger.accounts.map { SnLedgerClaimRow.of($0, progress: ledgerClaimProgress[$0.id], chain: ledgerChain, pools: pools) }
            + unavailableRows
            + extraRows.filter { !unavailableNoIds.contains($0.id.noId) }
    }

    var ledgerClaimFailures: [(key: SnLedgerAccountKey, failure: SnLedgerClaimFailure)] {
        ledgerClaimProgress.compactMap { key, state in
            if case .failed(let message) = state {
                return (key, SnLedgerClaimFailure.of(message))
            }
            return nil
        }
        .sorted { ($0.key.noId, $0.key.index) < ($1.key.noId, $1.key.index) }
    }

    var ledgerClaimFinished: Bool {
        !isLedgerClaiming && !ledgerClaimProgress.isEmpty
    }

    private func applyLedger(_ event: SnLedgerClaimEvent) {
        switch event {
        case .sent(let noId, let index, let txHash):
            ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .sent(txHash: txHash)
        case .confirmed(let noId, let index, let txHash, let amountRao):
            ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .confirmed(txHash: txHash, amountRao: amountRao)
        case .failed(let noId, let index, let message):
            let code = SnLedgerClaimFailure.code(of: message)
            if code == SnLedgerClaimFailure.alreadyClaimedCode {
                // another sender claimed it first, which is success; the
                // refresh after Done shows the account paid
                ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .alreadyClaimed
            } else if code == SnLedgerClaimFailure.needsGasCode {
                // nothing was sent for it: still claimable once the gas key
                // is topped up, which the gas card asks for
                ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .needsGas
            } else if code == SnLedgerClaimFailure.ledgerUnavailableCode, noId != 0, index == 0 {
                // the claim could not read this pool, whose account index it
                // does not know, and claimed the others: the pool, and an
                // account this sheet queued in it, are unavailable right now;
                // one the claim already sent keeps its state (Android's and
                // Linux's rule)
                var keys = ledgerClaimProgress.filter { $0.key.noId == noId && $0.value == .queued }.map(\.key)
                let poolKey = SnLedgerAccountKey(noId: noId, index: index)
                if ledgerClaimProgress[poolKey] == nil {
                    keys.append(poolKey)
                }
                for key in keys {
                    ledgerClaimProgress[key] = .unavailable
                }
            } else if SnLedgerClaimFailure.underFloor(message) {
                // the sdk's preflight found an account under the floor and
                // sent nothing for it: it waits, below the claim minimum, as
                // the sheet said, lone or beside others, and is no failure
                ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .underFloor
            } else {
                ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .failed(message: message)
            }
        case .done:
            isLedgerClaiming = false
            // an account the SDK did not claim is not left pending
            ledgerClaimProgress = ledgerClaimProgress.filter { $0.value != .queued }
            // a win whose award this claim, or another sender's, paid is no
            // longer unclaimed
            if ledgerClaimProgress.values.contains(where: \.paid) {
                refreshCtfWins()
            }
            Task { [weak self] in
                await self?.refreshSubnet()
            }
        }
    }
}

/// The value, or nil when the read threw, so an optional result (no wallet)
/// stays distinguishable from a failure.
private func earningsAttempt<T>(_ operation: () async throws -> T) async -> T? {
    do {
        return try await operation()
    } catch {
        return nil
    }
}
