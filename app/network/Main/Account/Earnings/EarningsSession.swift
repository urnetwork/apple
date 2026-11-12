//
//  EarningsSession.swift
//  URnetwork
//
//  What of Earnings belongs to the signed-in session rather than to a
//  screen (owner, 2026-11-12): the claims in flight, the v1 claim and the
//  settlement v2 claim, with their progress and their Done; and capture the
//  flag's won lines, with the reads after a claim.
//
//  The Account screens' view model (EarningsViewModel) does not live that
//  long everywhere: on macOS the sidebar's switch builds the Account screens,
//  so leaving Account drops it and coming back builds another. A claim in
//  flight is the session's, so its events and its Done land here whatever
//  screen is up; a view model built during it shows the claim as it went on,
//  with Claim held until Done, and no second claim starts while one is in
//  flight. A view model alive at a claim's Done reads the subnet again; one
//  built after it reads everything on its first visit anyway.
//
//  The tab view (iOS) and the split view (macOS) own one for the signed-in
//  account and hand it to the Account screens. A sign-out ends them, and this
//  with them, as it ends the claim: the claim's late events find nothing.
//

import Combine
import Foundation

/// A claim's Done, for the view models that live: each reads the subnet
/// again.
enum EarningsClaimDone: Equatable {
    /// the v1 claim's
    case claim
    /// the settlement v2 claim's, and whether it paid an account
    case ledgerClaim(paid: Bool)
}

@MainActor
final class EarningsSession: ObservableObject {

    let client: EarningsClient

    // MARK: the v1 claim

    @Published private(set) var claimProgress: [Int64: EarningsViewModel.ClaimRowState] = [:]
    @Published private(set) var isClaiming = false
    /// what the v1 claim in flight moves: the epochs it sends, as Claim found
    /// them; the v1 sheet's figure until Done
    @Published private(set) var claimMovingRao: Int64 = 0
    /// the epochs' claims the v1 sheet listed when Claim was pressed, which a
    /// sheet opened during the claim lists whatever a read since says, or a
    /// read that failed (as on Linux and Windows); none between claims
    @Published private(set) var claimListed: [SnEpochClaimInfo] = []

    // MARK: the settlement v2 claim

    @Published private(set) var ledgerClaimProgress: [SnLedgerAccountKey: EarningsViewModel.LedgerClaimRowState] = [:]
    @Published private(set) var isLedgerClaiming = false
    /// What the v2 claim in flight moves (owner, 2026-11-12): the accounts it
    /// sends whose amount is known and above the floor, as Claim found them
    /// when it was pressed (EarningsViewModel.ledgerClaimableAccounts). The
    /// claim sheet's figure until Done, which no event or read changes, so it
    /// never reads 0; none between claims.
    @Published private(set) var ledgerClaimSends: [SnLedgerAccountInfo] = []
    /// every account the sheet listed when Claim was pressed: a pool the
    /// claim cannot read makes each unsent one of it unavailable
    private var ledgerClaimListed: [SnLedgerAccountInfo] = []

    // MARK: capture the flag's wins

    /// every capture the flag slot the network's clients won whose award is
    /// not claimed yet, newest first, as the last good read gave them: a read
    /// that failed keeps them (every app, 2026-11-12), and none show until
    /// the session's first read answers
    @Published private(set) var ctfWins: [SnCtfWinInfo] = []
    /// the reads of the wins started so far, and the newest whose good answer
    /// the lines show: the reads run beside the refresh and never hold it up
    /// (the sdk waits up to a minute for the route), they overlap, and their
    /// answers land in any order
    private var ctfWinsReadsStarted = 0
    private var ctfWinsReadShown = 0
    /// a network answer has shown since the sign-in: a client answer never
    /// replaces its lines
    private var ctfWinsNetworkShown = false
    /// the reads of the wins after the last paying claim's Done
    /// (readCtfWinsAfterClaim)
    private var ctfWinsAfterClaim: Task<Void, Never>?
    /// waits between those reads: Task.sleep, or the tests' clock
    private let sleep: (Duration) async throws -> Void

    /// When the wins are read again after a claim that paid an account, after
    /// its Done, beside the read at Done (every app's schedule). The SDK's
    /// Done comes once the claim is in a block, but the server says a win is
    /// claimed only once vault2's claimed at the finalized head covers the
    /// claim, so the read at Done can still list a win the claim paid.
    static let ctfWinsReadsAfterClaim: [Duration] = [.seconds(30), .seconds(60), .seconds(120)]

    /// each claim's Done, for the view models that live
    let claimDone = PassthroughSubject<EarningsClaimDone, Never>()
    /// the Account screens' view model built last, the one on screen: only it
    /// reads the subnet again at a claim's Done, so a view model an earlier
    /// visit left behind costs no reads
    weak var screen: EarningsViewModel?

    init(
        client: EarningsClient,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    /// A claim of either kind is in flight. The gas key sends one claim at a
    /// time: the sdk reads its pending nonce as it signs, with no lock across
    /// a v1 and a v2 claim, so two at once could take the same nonce. Neither
    /// kind starts while one is in flight, as on Linux.
    var isAnyClaiming: Bool {
        isClaiming || isLedgerClaiming
    }

    // MARK: the v1 claim

    /// The v1 claim of `epochs`, of the claims the sheet `listed`: it moves
    /// those epochs' amounts as Claim found them. Nothing while a claim of
    /// either kind is in flight (isAnyClaiming).
    func claim(epochs: [Int64], listed: [SnEpochClaimInfo]) {
        guard !isAnyClaiming, !epochs.isEmpty else {
            return
        }
        let amounts = Dictionary(listed.map { ($0.epoch, $0.amountRao) }, uniquingKeysWith: { first, _ in first })
        isClaiming = true
        claimMovingRao = epochs.reduce(Int64(0)) { total, epoch in
            let (sum, overflow) = total.addingReportingOverflow(amounts[epoch] ?? 0)
            return overflow ? Int64.max : sum
        }
        claimListed = listed
        claimProgress = Dictionary(uniqueKeysWithValues: epochs.map { ($0, EarningsViewModel.ClaimRowState.queued) })
        client.claim(epochs: epochs) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.apply(event)
            }
        }
    }

    /// The sheet starts over, but for a claim in flight, whose progress a
    /// sheet opened again shows.
    func resetClaimProgress() {
        guard !isClaiming else {
            return
        }
        claimProgress = [:]
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
            claimMovingRao = 0
            claimListed = []
            claimDone.send(.claim)
        }
    }

    // MARK: the settlement v2 claim

    /// Claims every v2 account with something claimable (`sends`), the
    /// pool's and the capture the flag pool's alike, as the session's claim:
    /// the SDK sends one claim to STSettlementVault2 from the gas key, or, for
    /// two or more, one STClaimBatcher transaction that claims them all.
    /// `listed` is every account the sheet listed. Nothing while a claim of
    /// either kind is in flight: the gas key sends one at a time
    /// (isAnyClaiming).
    func claimLedger(sends accounts: [SnLedgerAccountInfo], listed: [SnLedgerAccountInfo]) {
        guard !isAnyClaiming, !accounts.isEmpty else {
            return
        }
        isLedgerClaiming = true
        ledgerClaimSends = accounts
        ledgerClaimListed = listed
        ledgerClaimProgress = Dictionary(accounts.map { ($0.id, EarningsViewModel.LedgerClaimRowState.queued) }, uniquingKeysWith: { first, _ in first })
        client.ledgerClaim { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyLedger(event)
            }
        }
    }

    /// The sheet starts over, but for a claim in flight, whose progress a
    /// sheet opened again shows.
    func resetLedgerClaimProgress() {
        guard !isLedgerClaiming else {
            return
        }
        ledgerClaimProgress = [:]
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
                // does not know, and claimed the others: the pool, and each
                // account of it the sheet listed or the claim reported that
                // the claim sent nothing for, whatever its index and under
                // the floor too, are unavailable right now; one the claim
                // sent keeps its state (Android's, Linux's and Windows' rule)
                let poolKey = SnLedgerAccountKey(noId: noId, index: index)
                let keys = Set(
                    ledgerClaimListed.filter { $0.noId == noId }.map(\.id)
                        + ledgerClaimProgress.keys.filter { $0.noId == noId }
                        + [poolKey]
                )
                for key in keys where ledgerClaimProgress[key]?.unsent ?? true {
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
            ledgerClaimSends = []
            ledgerClaimListed = []
            // an account the SDK did not claim is not left pending
            ledgerClaimProgress = ledgerClaimProgress.filter { $0.value != .queued }
            // a win whose award this claim, or another sender's, paid is no
            // longer unclaimed: the wins are read now, after any claim, as
            // every app reads them, and after one that paid again on the
            // schedule, as the server reads the claim only once the finalized
            // head covers it
            readCtfWins()
            let paid = ledgerClaimProgress.values.contains(where: \.paid)
            if paid {
                readCtfWinsAfterClaim()
            }
            claimDone.send(.ledgerClaim(paid: paid))
        }
    }

    // MARK: capture the flag's wins

    /// Reads the capture the flag wins: beside each refresh, at a claim's
    /// Done and at the times after it. Each read starts when asked, beside
    /// any still out, so the reads keep their times, and the lines show the
    /// newest read's good answer, whatever order the answers land in. A read
    /// that failed keeps the last good read's lines and never blanks them,
    /// nor drops an older read's good answer still to land: only a good read
    /// that no longer lists a win takes its line away, or a sign-out, which
    /// ends this session.
    ///
    /// A network answer beats a client answer (owner, 2026-11-12): a client
    /// answer holds only this client's wins, so once a network answer has
    /// shown since the sign-in, a client answer is a read that failed for its
    /// lines. A client answer shows only while no network answer has, as
    /// from a server before the network answer, whose every answer is a
    /// client's. A network answer replaces a client answer's lines whatever
    /// order their reads started in, and another network answer's unless that
    /// read is newer.
    func readCtfWins() {
        ctfWinsReadsStarted += 1
        let read = ctfWinsReadsStarted
        let client = client
        Task { [weak self] in
            let answer = await client.ctfUnclaimedWins()
            self?.applyCtfWins(answer, read: read)
        }
    }

    private func applyCtfWins(_ answer: SnCtfWinsAnswer?, read: Int) {
        guard let answer else {
            return
        }
        if answer.fromClient {
            guard !ctfWinsNetworkShown, read > ctfWinsReadShown else {
                return
            }
        } else if ctfWinsNetworkShown, read <= ctfWinsReadShown {
            return
        }
        ctfWinsReadShown = read
        ctfWinsNetworkShown = ctfWinsNetworkShown || !answer.fromClient
        ctfWins = answer.wins
    }

    /// After a claim that paid an account, the wins are read again at each of
    /// ctfWinsReadsAfterClaim after its Done, beside the read at Done: a win
    /// the claim paid reads claimed only once the finalized head covers the
    /// claim. Each read starts at its time and replaces the lines unless it
    /// failed (readCtfWins). The next paying claim's Done starts the reads
    /// over; one that paid nothing leaves them be. They run with the session,
    /// whatever screen is up, and a sign-out, which ends it, ends them.
    private func readCtfWinsAfterClaim() {
        ctfWinsAfterClaim?.cancel()
        let sleep = sleep
        ctfWinsAfterClaim = Task { [weak self] in
            var afterDone = Duration.zero
            for at in Self.ctfWinsReadsAfterClaim {
                do {
                    try await sleep(at - afterDone)
                } catch {
                    return
                }
                afterDone = at
                guard !Task.isCancelled, let self else {
                    return
                }
                self.readCtfWins()
            }
        }
    }
}
