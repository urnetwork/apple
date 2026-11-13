//
//  EarningsViewModel.swift
//  URnetwork
//
//  State of the points-first Earnings screen. Points come from the account
//  points store; this holds the subnet layer, which only carries data once a
//  Bittensor coldkey is attached: the wallet, the epoch history rows, the
//  vault claims, the settlement v2 accounts (the pool's and the capture the
//  flag pool's) and their claim, the gas key balance and the network's Top
//  200 standing on the Protocol leaderboard. The claims in flight and
//  capture the flag's won lines are the signed-in session's (EarningsSession),
//  which the app holds for every window and which outlives this view model
//  where the Account screens do not.
//
//  The subnet layer's reads overlap and land in any order, so each is
//  numbered as it starts: an answer never replaces one that a read started
//  after it put there, and Claim of either kind waits for a read that
//  started after that kind's last claim ended (owner, 2026-11-12).
//

import Combine
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

        /// the claim sent nothing for the account: still queued, or the sdk
        /// held it back (needs_gas, under the floor, its pool unavailable)
        var unsent: Bool {
            switch self {
            case .queued, .needsGas, .underFloor, .unavailable:
                return true
            case .sent, .confirmed, .alreadyClaimed, .failed:
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

    /// the v1 claim's progress, the session's (EarningsSession)
    var claimProgress: [Int64: ClaimRowState] {
        session.claimProgress
    }
    var isClaiming: Bool {
        session.isClaiming
    }

    /// the settlement v2 accounts from the latest ledger read
    @Published private(set) var ledger: SnLedgerLoad = .loading
    /// vault2 and the explorer link from the SDK's chain settings
    @Published private(set) var ledgerChain: SnLedgerChainInfo = .unconfigured
    /// the v2 claim's progress, the session's (EarningsSession): a claim in
    /// flight is the signed-in session's, never this view model's
    var ledgerClaimProgress: [SnLedgerAccountKey: LedgerClaimRowState] {
        session.ledgerClaimProgress
    }
    var isLedgerClaiming: Bool {
        session.isLedgerClaiming
    }

    /// what URnetwork's claim relay says of the network's v2 balance; nil
    /// until read, or with no sdk to ask
    @Published private(set) var claimStatus: SnClaimStatusInfo?
    /// the claim sheet's Claim now: nil before a tap
    @Published private(set) var claimNowOutcome: SnClaimNowOutcome?
    @Published private(set) var isClaimingNow = false

    /// every capture the flag slot the network's clients won whose award is
    /// not claimed yet, newest first, for a line each under the Settlement v2
    /// balances, as the session's last good read gave them (EarningsSession):
    /// a read that failed keeps them (every app, 2026-11-12), a client answer
    /// never replaces a network answer's, and none show until the session's
    /// first read answers
    var ctfWins: [SnCtfWinInfo] {
        session.ctfWins
    }

    /// the signed-in session's claims and won lines
    let session: EarningsSession
    let client: EarningsClient
    private var walletSubscription: EarningsSubscription?
    private var chainSettingsSynced = false
    /// the session's changes, which this view model's screens draw
    private var sessionChanges: AnyCancellable?
    /// the session's claims' Done
    private var sessionClaimsDone: AnyCancellable?

    /// the reads of the subnet layer started so far (refreshSubnet), each
    /// numbered as it starts
    private var subnetReadsStarted = 0
    /// the read each part of the layer shows, the v1 claims, the v2 accounts
    /// and the gas balance, with the claims of its kind ended when it started
    private var claimsShown = EarningsReadShown()
    private var ledgerShown = EarningsReadShown()
    private var gasShown = EarningsReadShown()

    /// When the wins are read again after a claim that paid an account, after
    /// its Done (EarningsSession.ctfWinsReadsAfterClaim, every app's
    /// schedule).
    static var ctfWinsReadsAfterClaim: [Duration] {
        EarningsSession.ctfWinsReadsAfterClaim
    }

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

    /// The Account screens' view model on the signed-in session's claims and
    /// won lines, and its client: each window's own, on the one session.
    init(session: EarningsSession) {
        self.session = session
        let client = session.client
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
        sessionChanges = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // a claim's Done, whichever window's view model started it: the
        // subnet as the chain now has it, read by every view model alive,
        // the one of each window that shows Account (macOS) and the tab
        // view's (iOS), so no window keeps the balances the claim paid with
        // Claim on them. One whose Account screens went is gone with them.
        sessionClaimsDone = session.claimDone.sink { [weak self] _ in
            Task { [weak self] in
                await self?.refreshSubnet()
            }
        }
    }

    /// A view model with a session of its own, as previews and tests have.
    convenience init(
        client: EarningsClient,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(session: EarningsSession(client: client, sleep: sleep))
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

    /// the Settlement v2 tile, or nil for none; its Claim opens the claim in
    /// flight while there is one, and else waits for a read of the accounts
    /// that started after the last v2 claim ended
    var ledgerTile: SnLedgerTilePresentation? {
        SnLedgerTilePresentation.of(
            load: ledger,
            claimConfigured: ledgerChain.claimConfigured,
            claimInFlight: isLedgerClaiming,
            transferFloorRao: ledgerTransferFloorRao,
            readSinceClaim: ledgerReadSinceClaim
        )
    }

    /// The v1 claims shown come from a read that started after the last v1
    /// claim ended (Done). A read that started before it, still out at the
    /// Done or answered before it, can list the epochs the claim paid as
    /// claimable, and a v1 Claim of them is a transaction the vault reverts,
    /// with its gas spent: no v1 Claim is offered from it (owner,
    /// 2026-11-12). Claim waits for the read the Done starts; if that read
    /// fails, the claims shown stay as they were, and Claim waits for the
    /// next good one.
    var claimsReadSinceClaim: Bool {
        claimsShown.claimsEnded == session.claimsEnded
    }

    /// The same for the v2 accounts and the last v2 claim: no v2 Claim is
    /// offered from a ledger read that started before it ended.
    var ledgerReadSinceClaim: Bool {
        ledgerShown.claimsEnded == session.ledgerClaimsEnded
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
    /// together: its button says "Claim both"; during a claim, whether the
    /// claim sends exactly those two
    var ledgerClaimsBoth: Bool {
        ledgerPools.claimsBoth(isLedgerClaiming ? session.ledgerClaimSends : ledgerClaimableAccounts)
    }

    /// what a v2 claim pays in all, saturating rather than trapping on an
    /// absurd ledger answer
    var ledgerClaimableRao: Int64 {
        Self.total(ledgerClaimableAccounts)
    }

    /// The v2 claim sheet's figure, which its Claim names too. Between claims
    /// it is what a claim pays (ledgerClaimableRao). During a claim it is what
    /// the claim moves (owner, 2026-11-12): the accounts it sends whose
    /// amount is known and above the floor, as Claim found them
    /// (EarningsSession.ledgerClaimSends), fixed until Done as on Android,
    /// Linux and Windows. No read since changes it and no account the claim
    /// confirms takes from it, so it never reads 0; an account the SDK then
    /// sends nothing for says so on its own line (needs_gas: claimable, with
    /// the gas card's top-up).
    var ledgerClaimFigureRao: Int64 {
        isLedgerClaiming ? Self.total(session.ledgerClaimSends) : ledgerClaimableRao
    }

    private static func total(_ accounts: [SnLedgerAccountInfo]) -> Int64 {
        accounts.reduce(0) { total, account in
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

    /// the v2 claim sheet's Claim, which waits for a claim of either kind in
    /// flight: the gas key sends one at a time (EarningsSession.isAnyClaiming);
    /// and for a read of the accounts that started after the last v2 claim
    /// ended (ledgerReadSinceClaim)
    var ledgerClaimEnabled: Bool {
        ledgerReadSinceClaim && ledgerChain.claimConfigured && !ledgerClaimableAccounts.isEmpty && !ledgerNeedsGas
            && !session.isAnyClaiming
    }

    /// the v1 claim sheet's Claim: something claimable in a read that started
    /// after the last v1 claim ended (claimsReadSinceClaim), gas, and no claim
    /// of either kind in flight (EarningsSession.isAnyClaiming)
    var claimEnabled: Bool {
        claimsReadSinceClaim && !claimableClaims.isEmpty && !needsGas && !session.isAnyClaiming
    }

    /// the v2 claim sheet has no amount to show, never 0: the ledger could not
    /// be read, or it read no account and could not read a pool. A claim in
    /// flight has its figure, whatever the reads since say.
    var ledgerClaimUnavailable: Bool {
        !isLedgerClaiming && (ledger == .unavailable || (ledger.accounts.isEmpty && !ledger.unavailablePools.isEmpty))
    }

    /// The v2 claim sheet's figure (ledgerClaimFigureRao) is a total to show.
    /// During a claim always: a claim sends something. Between claims: a line
    /// holds an amount above the floor a claim moves, or no line holds
    /// anything left, a true 0. While what is left is all under the floor, in
    /// a pool that could not be read or of an amount not known yet, the lines
    /// say why and the sheet shows no figure, never 0 (Windows' and Android's
    /// claim dialogs).
    var ledgerClaimTotalKnown: Bool {
        if isLedgerClaiming {
            return ledgerClaimFigureRao > 0
        }
        let left = ledgerClaimRowsLeft
        return left.contains(.moves) || !left.contains(.noFigure)
    }

    /// what each line of the v2 claim sheet has left for its figure, at the
    /// relay's floor
    var ledgerClaimRowsLeft: [SnLedgerClaimRow.Left] {
        let floor = ledgerTransferFloorRao
        return ledgerClaimRows.map { $0.left(transferFloorRao: floor) }
    }

    /// How and when the provider is paid, for the foot of the points card;
    /// nil until the wallet read settles (a failed read with no cached wallet
    /// says nothing about the coldkey).
    /// `localKeyPaid`: the network's consent pays the payout key on this
    /// device, a coldkey before the wallet read lists it, so there is no
    /// coldkey left to set.
    /// Its Claim, which opens the v1 sheet, waits as the tile's does for a
    /// read of the claims that started after the last v1 claim ended, but for
    /// a v1 claim in flight, whose sheet it opens.
    func payoutLine(nowMillis: Int64, formatTime: (Int64) -> String, localKeyPaid: Bool = false) -> SnPayoutLine? {
        let hasColdkey = hasWallet || localKeyPaid
        return SnPayoutLine.of(
            walletKnown: loadedOnce && (hasColdkey || !walletLoadFailed),
            hasColdkey: hasColdkey,
            totalClaimableRao: totalClaimableRao,
            schedule: schedule,
            nowMillis: nowMillis,
            formatTime: formatTime,
            claimOffered: claimsReadSinceClaim || isClaiming
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
        session.readCtfWins()
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

    /// The layer that only exists with a wallet: gas key, balance, claims,
    /// the settlement v2 accounts.
    ///
    /// The reads overlap (a refresh, a wallet change, the read at each claim's
    /// Done) and their answers land in any order. Each read is numbered as it
    /// starts, with the claims of each kind ended by then (EarningsSession):
    /// each part shows an answer only if no read that started after it shows
    /// there already, so an answer from before a claim's Done never replaces
    /// the one read after it, and Claim waits for a read that started after
    /// its kind's last Done (claimsReadSinceClaim, ledgerReadSinceClaim).
    func refreshSubnet() async {
        subnetReadsStarted += 1
        let read = subnetReadsStarted
        let claimsEnded = session.claimsEnded
        let ledgerClaimsEnded = session.ledgerClaimsEnded
        guard hasWallet else {
            // nothing to read: the layer is empty at once, and no read out
            // from before puts it back
            if claimsShown.shows(read, claimsEnded: claimsEnded) {
                claims = []
                totalClaimableRao = 0
                schedule = nil
            }
            if gasShown.shows(read) {
                gasTao = nil
            }
            if ledgerShown.shows(read, claimsEnded: ledgerClaimsEnded) {
                ledger = .loaded([])
            }
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
        // a failed read is unknown
        if gasShown.shows(read) {
            gasTao = balance
        }
        // a failed read keeps the claims shown
        if let claimsResult, claimsShown.shows(read, claimsEnded: claimsEnded) {
            claims = claimsResult.claims.sorted { $0.epoch > $1.epoch }
            totalClaimableRao = claimsResult.totalClaimableRao
            schedule = claimsResult.schedule
        }
        // a read's answer stands until one that started after it answers: a
        // failed read is unavailable even after a good one, so no claim is
        // offered on balances that could not be read; a pool that could not
        // be read is unavailable on its own
        if ledgerShown.shows(read, claimsEnded: ledgerClaimsEnded) {
            if let ledgerResult {
                ledger = .loaded(ledgerResult.accounts, unavailablePools: ledgerResult.unavailablePools)
            } else {
                ledger = .unavailable
            }
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

    /// The v1 claim, the session's (EarningsSession): its events and its Done
    /// land whatever screen is up, and none starts while a claim of either
    /// kind is in flight, nor from a claims read that started before the last
    /// v1 claim ended (claimsReadSinceClaim). What it moves is what the claims
    /// read gives `epochs`.
    func claim(epochs: [Int64]) {
        guard claimsReadSinceClaim else {
            return
        }
        session.claim(epochs: epochs, listed: claims)
    }

    /// The v1 sheet's epochs: the claims read's, and during a claim the ones
    /// the sheet listed when Claim was pressed (EarningsSession.claimListed),
    /// which a read since never changes or empties, as Linux's and Windows'
    /// sheets keep the claim's own rows.
    var claimSheetClaims: [SnEpochClaimInfo] {
        isClaiming ? session.claimListed : claims
    }

    /// The count under the v1 sheet's figure ("Claimable epochs: N"): the
    /// claimable epochs, and during a claim the epochs it sends, fixed with
    /// the figure until Done (as on Windows).
    var claimSheetClaimableCount: Int {
        isClaiming ? claimProgress.count : claimableClaims.count
    }

    /// The v1 tile's Claim: something claimable in a read that started after
    /// the last v1 claim ended (claimsReadSinceClaim), or a claim in flight,
    /// which it opens whatever the last read says (as the v2 tile's does, and
    /// the other apps' v1 Claim).
    var claimTileEnabled: Bool {
        (claimsReadSinceClaim && !claimableClaims.isEmpty) || isClaiming
    }

    /// The v1 claim sheet's figure, which its Claim names too: what is
    /// unclaimed, and during a claim what the claim moves, the epochs it sends
    /// as Claim found them, fixed until Done (owner, 2026-11-12, as on
    /// Android and Linux), so a read since never makes it 0.
    var claimFigureRao: Int64 {
        isClaiming ? session.claimMovingRao : totalClaimableRao
    }

    /// The v1 sheet starts over, but for a claim in flight, whose progress a
    /// sheet opened again shows.
    func resetClaimProgress() {
        session.resetClaimProgress()
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

    // MARK: settlement v2 claims

    /// Claims every v2 account with something claimable, the pool's and the
    /// capture the flag pool's alike, as the signed-in session's claim
    /// (EarningsSession): the SDK sends one claim to STSettlementVault2 from
    /// the gas key, or, for two or more, one STClaimBatcher transaction that
    /// claims them all. Its events and its Done land whatever screen is up,
    /// and none starts while one is in flight, nor from a ledger read that
    /// started before the last v2 claim ended (ledgerReadSinceClaim).
    func claimLedger() {
        guard ledgerChain.claimConfigured, ledgerReadSinceClaim else {
            return
        }
        session.claimLedger(sends: ledgerClaimableAccounts, listed: ledger.accounts)
    }

    /// The v2 sheet starts over, but for a claim in flight, whose progress a
    /// sheet opened again shows.
    func resetLedgerClaimProgress() {
        session.resetLedgerClaimProgress()
    }

    /// Each account's line in the v2 claim sheet, then each pool that could
    /// not be read. What the claim reports beyond them follows, as Android's,
    /// Linux's and Windows' claim rows do: an account its own read found in a
    /// pool the sheet's read could not read takes that pool's line, and a pool
    /// it could not read that the sheet's read did not list gets a line.
    /// During a claim an account it sends shows the amount Claim found, as
    /// Windows' rows do, whatever a read since says (on macOS the view model
    /// built on coming back to Account reads the ledger again).
    var ledgerClaimRows: [SnLedgerClaimRow] {
        let sends = isLedgerClaiming
            ? Dictionary(session.ledgerClaimSends.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
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
        let extraRows = extra.map {
            SnLedgerClaimRow.found($0.key, kind: $0.kind, progress: $0.state, chain: ledgerChain, pools: pools, sentRao: sends[$0.key]?.claimableRao)
        }
        let unavailableRows = ledger.unavailablePools.flatMap { pool in
            let taken = extraRows.filter { $0.id.noId == pool.noId }
            return taken.isEmpty ? [SnLedgerClaimRow.of(pool, pools: pools)] : taken
        }
        return ledger.accounts.map { SnLedgerClaimRow.of(sends[$0.id] ?? $0, progress: ledgerClaimProgress[$0.id], chain: ledgerChain, pools: pools) }
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
}

/// Which read of the subnet layer (EarningsViewModel.refreshSubnet) one part
/// of it shows, the v1 claims, the v2 accounts or the gas balance, and how
/// many claims of the part's kind had ended (EarningsSession.claimsEnded,
/// ledgerClaimsEnded) when that read started. The reads overlap and their
/// answers land in any order: one shows only if no read that started after
/// it shows already.
struct EarningsReadShown: Equatable {

    /// the read shown, numbered as the reads start; 0 before any
    private(set) var read = 0
    /// the claims of the part's kind that had ended when it started
    private(set) var claimsEnded = 0

    /// Read `read`, started when `claimsEnded` claims of the part's kind had
    /// ended, answered: it is the read shown from now, unless one that
    /// started after it shows already (false, and nothing changes).
    mutating func shows(_ read: Int, claimsEnded: Int = 0) -> Bool {
        guard self.read < read else {
            return false
        }
        self.read = read
        self.claimsEnded = claimsEnded
        return true
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
