//
//  EarningsSession.swift
//  URnetwork
//
//  What of Earnings belongs to the signed-in session rather than to a
//  screen (owner, 2026-11-12): the claims in flight, the v1 claim and the
//  settlement v2 claim, with their progress and their Done; and capture the
//  flag's won lines, with the reads after a claim.
//
//  The session is app-wide (owner, 2026-11-12: "make the session
//  app-wide"): the app holds one for the signed-in account
//  (EarningsSessions), and every window and view shares it. On macOS each
//  window (File > New Window) shows Account on the same session, so a claim
//  in flight shows in every window, and Claim is held in every window while
//  any claim runs. A sign-out ends it, and a second account's sign-in gets a
//  fresh one.
//
//  The Account screens' view model (EarningsViewModel) does not live that
//  long everywhere: on macOS the sidebar's switch builds the Account screens,
//  so leaving Account drops it and coming back builds another, and each
//  window builds its own. A claim in flight is the session's, so its events
//  and its Done land here whatever screen is up; a view model built during it
//  shows the claim as it went on, with Claim held until Done, and no second
//  claim starts while one is in flight. Every view model alive at a claim's
//  Done, one for each window that shows Account, reads the subnet again; one
//  built after it reads everything on its first visit anyway. The session
//  counts the claims ended of each kind, so that each view model offers Claim
//  only from a read that started after its kind's last Done.
//

import Combine
import Foundation

/// A claim's Done, for the view models that live, one for each window that
/// shows Account: each reads the subnet again.
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

    /// each claim's Done, for the view models that live: each window's
    /// Account screens read the subnet again
    let claimDone = PassthroughSubject<EarningsClaimDone, Never>()

    // MARK: the claims ended

    /// How many v1 claims have ended (Done). A read of the claims that started
    /// before the last one ended can still list the epochs it paid as
    /// claimable, and a v1 claim of them is a transaction the vault reverts,
    /// with its gas spent: each view model offers a v1 Claim only from a read
    /// that started after it (EarningsViewModel.claimsReadSinceClaim, owner,
    /// 2026-11-12). Counted by kind: a v2 claim pays nothing a v1 read lists,
    /// nor the reverse, and the gas both spend the sdk checks again before it
    /// sends.
    @Published private(set) var claimsEnded = 0
    /// the same for the v2 claims and the reads of the ledger
    /// (EarningsViewModel.ledgerReadSinceClaim)
    @Published private(set) var ledgerClaimsEnded = 0

    /// A sign-out, or another account's sign-in, ended the session (end()):
    /// it starts nothing more, and nothing landing after takes it on.
    private(set) var ended = false

    init(
        client: EarningsClient,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    /// A claim of either kind is in flight, from any window. The gas key
    /// sends one claim at a time: the sdk reads its pending nonce as it
    /// signs, with no lock across a v1 and a v2 claim, so two at once could
    /// take the same nonce. Neither kind starts while one is in flight, as
    /// on Linux, and every window's Claim waits for it (the session is
    /// app-wide).
    var isAnyClaiming: Bool {
        isClaiming || isLedgerClaiming
    }

    /// Ends the session: a sign-out, or another account's sign-in
    /// (EarningsSessions). The claims' late events and the reads' late
    /// answers find nothing, as when the session went with the screens: the
    /// reads after a claim stop, and no claim or read starts. The screens
    /// that drew it go with the sign-out.
    func end() {
        ended = true
        ctfWinsAfterClaim?.cancel()
        ctfWinsAfterClaim = nil
    }

    // MARK: the v1 claim

    /// The v1 claim of `epochs`, of the claims the sheet `listed`: it moves
    /// those epochs' amounts as Claim found them. Nothing while a claim of
    /// either kind is in flight (isAnyClaiming), or once the session ended.
    func claim(epochs: [Int64], listed: [SnEpochClaimInfo]) {
        guard !ended, !isAnyClaiming, !epochs.isEmpty else {
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
        guard !ended else {
            return
        }
        switch event {
        case .sent(let epoch, let txHash):
            claimProgress[epoch] = .sent(txHash: txHash)
        case .confirmed(let epoch, let txHash, let amountRao):
            claimProgress[epoch] = .confirmed(txHash: txHash, amountRao: amountRao)
        case .failed(let epoch, let message):
            claimProgress[epoch] = .failed(message: message)
        case .done:
            isClaiming = false
            claimsEnded += 1
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
    /// (isAnyClaiming); nor once the session ended.
    func claimLedger(sends accounts: [SnLedgerAccountInfo], listed: [SnLedgerAccountInfo]) {
        guard !ended, !isAnyClaiming, !accounts.isEmpty else {
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
        guard !ended else {
            return
        }
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
            ledgerClaimsEnded += 1
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
    ///
    /// None starts once the session ended, and an answer that lands after
    /// it shows nowhere.
    func readCtfWins() {
        guard !ended else {
            return
        }
        ctfWinsReadsStarted += 1
        let read = ctfWinsReadsStarted
        let client = client
        Task { [weak self] in
            let answer = await client.ctfUnclaimedWins()
            self?.applyCtfWins(answer, read: read)
        }
    }

    private func applyCtfWins(_ answer: SnCtfWinsAnswer?, read: Int) {
        guard !ended, let answer else {
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
    /// whatever screen or window is up, and a sign-out, which ends it (end()),
    /// ends them.
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

/// The app's EarningsSession: one for the signed-in account, which every
/// window and view shares (owner, 2026-11-12: "make the session app-wide").
/// Before, the tab view (iOS) and each window's split view (macOS) built
/// their own, so a second window (File > New Window, ⌘N) knew nothing of a
/// claim in flight in the first: its Claim followed its own read, and could
/// start a second claim from the same gas key while the first ran.
///
/// The app makes one and has it follow the signed-in device for the life of
/// the process, whatever window is up (NetworkApp): a sign-in's device gets
/// a fresh session, the same device keeps its own, and a sign-out (no
/// device) ends it, as another device's sign-in does before that device
/// gets its own. Each window's screens draw the session of the device they
/// show (session(for:)).
@MainActor
final class EarningsSessions: ObservableObject {

    /// the signed-in account's session; nil while signed out
    @Published private(set) var current: EarningsSession?
    /// the signed-in device `current` is for
    private weak var device: AnyObject?
    /// the signed-in device followed (follow)
    private var following: AnyCancellable?

    /// The session of `device` while it is the device signed in, which every
    /// window's screens share; nil for any other device, as one a sign-out
    /// or a later sign-in replaced.
    func session(for device: AnyObject) -> EarningsSession? {
        device === self.device ? current : nil
    }

    /// Follows the signed-in device, DeviceManager's, from the one signed in
    /// now, for as long as this lives (signedIn).
    func follow<Device: AnyObject, Devices: Publisher>(
        _ devices: Devices,
        makeSession: @escaping @MainActor (Device) -> EarningsSession
    ) where Devices.Output == Device?, Devices.Failure == Never {
        following = devices.sink { [weak self] device in
            self?.signedIn(device, makeSession: makeSession)
        }
    }

    /// The device signed in now: the same device keeps its session; none (a
    /// sign-out) ends it; another (a second account's sign-in) ends it and
    /// gets a fresh one from `makeSession`.
    func signedIn<Device: AnyObject>(_ device: Device?, makeSession: @MainActor (Device) -> EarningsSession) {
        if let device, device === self.device, current != nil {
            return
        }
        current?.end()
        self.device = device
        current = device.map(makeSession)
    }
}
