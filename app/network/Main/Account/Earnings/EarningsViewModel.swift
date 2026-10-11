//
//  EarningsViewModel.swift
//  URnetwork
//
//  State of the points-first Earnings screen. Points come from the account
//  points store; this holds the subnet layer, which only carries data once a
//  Bittensor coldkey is attached: the wallet, the epoch history rows, the
//  vault claims, the settlement v2 accounts and their claim, the gas key
//  balance and the Top 200 head status.
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
    @Published private(set) var head: SnHeadInfo?
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

    let client: EarningsClient
    private var walletSubscription: EarningsSubscription?
    private var chainSettingsSynced = false

    /// a rough per-claim gas reserve in TAO; the SDK reports the real
    /// shortfall as a failed claim
    static let gasTaoPerClaim = 0.005

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

    var showsTop200Tile: Bool {
        guard let head else { return false }
        return head.eligible || head.bound
    }

    /// the Settlement v2 tile, or nil for none
    var ledgerTile: SnLedgerTilePresentation? {
        SnLedgerTilePresentation.of(load: ledger, claimConfigured: ledgerChain.claimConfigured, isClaiming: isLedgerClaiming)
    }

    /// the v2 accounts a claim pays: every one with something claimable
    var ledgerClaimableAccounts: [SnLedgerAccountInfo] {
        ledger.accounts.filter { $0.claimableRao > 0 }
    }

    /// what a v2 claim pays in all, saturating rather than trapping on an
    /// absurd ledger answer
    var ledgerClaimableRao: Int64 {
        ledgerClaimableAccounts.reduce(0) { total, account in
            let (sum, overflow) = total.addingReportingOverflow(account.claimableRao)
            return overflow ? Int64.max : sum
        }
    }

    var ledgerGasNeededTao: Double {
        Self.ledgerGasTaoPerClaim * Double(max(1, ledgerClaimableAccounts.count))
    }

    /// the gas key cannot cover the v2 claims, or a v2 claim just failed
    /// needs_gas: the gas card shows the top-up
    var ledgerNeedsGas: Bool {
        (gasTao ?? 0) < ledgerGasNeededTao || ledgerClaimFailures.contains { $0.failure == .needsGas }
    }

    /// the v2 claim sheet's Claim
    var ledgerClaimEnabled: Bool {
        ledgerChain.claimConfigured && !ledgerClaimableAccounts.isEmpty && !ledgerNeedsGas && !isLedgerClaiming
    }

    /// How and when the provider is paid, for the foot of the points card;
    /// nil until the wallet read settles (a failed read with no cached wallet
    /// says nothing about the coldkey).
    func payoutLine(nowMillis: Int64, formatTime: (Int64) -> String) -> SnPayoutLine? {
        SnPayoutLine.of(
            walletKnown: loadedOnce && (hasWallet || !walletLoadFailed),
            hasColdkey: hasWallet,
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

        // `try?` flattens an optional result, so a failed wallet or head read
        // would read as "none"; earningsAttempt keeps the failure distinct
        let client = client
        async let walletTask = earningsAttempt { try await client.fetchWallet() }
        async let epochsTask = earningsAttempt { try await client.accountEpochs() }
        async let headTask = earningsAttempt { try await client.head() }

        let (walletResult, epochsResult, headResult) = await (walletTask, epochsTask, headTask)
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
        if let headResult {
            head = headResult
        }

        await refreshSubnet()

        loadedOnce = true
        isLoading = false
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
        async let ledgerTask: [SnLedgerAccountInfo]? = try? client.ledgerAccounts()
        let (balance, claimsResult, ledgerResult) = await (balanceTask, claimsTask, ledgerTask)
        gasTao = balance
        if let claimsResult {
            claims = claimsResult.claims.sorted { $0.epoch > $1.epoch }
            totalClaimableRao = claimsResult.totalClaimableRao
            schedule = claimsResult.schedule
        }
        // the latest read decides: a failed read is unavailable even after a
        // good one, so no claim is offered on balances that could not be read
        if let ledgerResult {
            ledger = .loaded(ledgerResult)
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

    /// Claims every v2 account with something claimable: the SDK sends one
    /// claim per pool to STSettlementVault2 from the gas key.
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

    /// each account's line in the v2 claim sheet
    var ledgerClaimRows: [SnLedgerClaimRow] {
        ledger.accounts.map { SnLedgerClaimRow.of($0, progress: ledgerClaimProgress[$0.id], chain: ledgerChain) }
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
            // already_claimed: another sender claimed it first, which is
            // success; the refresh after Done shows the account paid
            if SnLedgerClaimFailure.code(of: message) == SnLedgerClaimFailure.alreadyClaimedCode {
                ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .alreadyClaimed
            } else {
                ledgerClaimProgress[SnLedgerAccountKey(noId: noId, index: index)] = .failed(message: message)
            }
        case .done:
            isLedgerClaiming = false
            // an account the SDK did not claim is not left pending
            ledgerClaimProgress = ledgerClaimProgress.filter { $0.value != .queued }
            Task { [weak self] in
                await self?.refreshSubnet()
            }
        }
    }
}

/// The value, or nil when the read threw, so an optional result (no wallet,
/// no head status) stays distinguishable from a failure.
private func earningsAttempt<T>(_ operation: () async throws -> T) async -> T? {
    do {
        return try await operation()
    } catch {
        return nil
    }
}
