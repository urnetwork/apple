//
//  SnLedgerTests.swift
//  networkTests
//
//  Settlement v2 on the Earnings screen, beside the v1 claims, which are
//  read and claimed as before: the v2 accounts read through the SDK (a
//  ledger that cannot be read is unavailable, never zero), the v2 tile in
//  every state (unavailable, pending, several pools, v2 claims configured or
//  not), and the v2 claim's progress: Sent with the explorer link, Confirmed
//  with the vault's amount, failures in the v1 claim's words, needs_gas
//  showing the gas top-up, already_claimed as success, and the accounts read
//  again after Done. The new strings are translated in every locale.
//
//  Capture the flag (sn/CAPTURETHEFLAG.md §10): a capture the flag account is
//  a row of its own beside the provider pool's, each named from its kind; a
//  pool the operator could not read is unavailable in its own row and hides
//  no other; one claim claims both pools ("Claim both"), as the SDK's one
//  batch transaction, within one claim's gas reserve; the relay's claim sheet
//  lists each pool's account; and entries without a kind, from a server that
//  predates it, read as before.
//
//  The owner's rules of 2026-11-11, for every app: any account under the
//  relay's transfer floor, lone or beside others, reads "Below the claim
//  minimum" and is left out of the claim, and the sdk's AmountTooLow is never
//  a failure; an account the gas key could not pay for (needs_gas, the sdk
//  claiming the largest first) is still claimable, with the top-up; and each
//  unclaimed win has a line, newest first. The claim's rows follow Android's,
//  Linux's and Windows': a pool's ledger_unavailable leaves a sent account's
//  state, and an account the claim found takes its unreadable pool's line.
//
//  The fixes of the review of 2026-11-12: the wins are read at every claim's
//  Done, and after a claim that paid an account again 30 s, 60 s and 120 s
//  after it (every app's schedule), tested with a server that still says
//  unclaimed at first; a read that failed keeps the last good read's lines
//  (every app); the claim sheet shows no figure while nothing above the floor
//  is left and something is under it (whatever the sdk said of it since),
//  unavailable or of an amount not known yet, as Windows' and Android's; and a
//  pool the claim cannot read makes each of its listed accounts the claim sent
//  nothing for unavailable, whatever its index.
//
//  The session is app-wide (owner, 2026-11-12): the app holds one for the
//  signed-in device (EarningsSessions), which two windows' Account screens
//  share, so a claim started in one shows in the other and holds Claim there
//  until Done; a sign-out ends it, and a second account's sign-in, or the
//  tab view's on iOS, gets a fresh one.
//

import Combine
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct SnLedgerTests {

    // nonisolated: default arguments and static initializers read them
    nonisolated private static let vault2 = "0x2222222222222222222222222222222222222222"
    nonisolated private static let configured = SnLedgerChainInfo(
        vault2Address: vault2,
        explorerTxUrl: "https://evm.taostats.io/tx/%s"
    )

    nonisolated private static let key = SnLedgerAccountKey(noId: 1, index: 42)

    /// pool 1's capture the flag pool: 2^32 + 1
    nonisolated private static let ctfNoId: Int64 = 4_294_967_297
    nonisolated private static let ctfKey = SnLedgerAccountKey(noId: ctfNoId, index: 7)

    /// the relay's transfer floor at its last price, in rao of α: 0.0005 TAO
    /// at about 0.0066 TAO/α
    nonisolated private static let floorRao: Int64 = 75_000_000

    /// this device's client, which a client's answer of the wins names
    nonisolated private static let clientId = "3f6c2a1e-8d4b-4c7a-9e21-5b0d7f3a9c64"

    /// pool 1's account: 5 α finalized, 1.759 α paid, 3.241 α claimable
    nonisolated private static func account(
        noId: Int64 = 1,
        index: Int64 = 42,
        finalizedRao: Int64 = 5_000_000_000,
        claimableRao: Int64 = 3_241_000_000,
        paidRao: Int64 = 1_759_000_000,
        pending: Bool = false,
        pendingRao: Int64 = 0,
        kind: SnLedgerPoolKind = .pool
    ) -> SnLedgerAccountInfo {
        SnLedgerAccountInfo(
            vault: vault2,
            noId: noId,
            index: index,
            finalizedRao: finalizedRao,
            claimableRao: claimableRao,
            paidRao: paidRao,
            pending: pending,
            pendingRao: pendingRao,
            kind: kind
        )
    }

    /// the same account once all of it is paid
    nonisolated private static let paid = account(claimableRao: 0, paidRao: 5_000_000_000)

    /// the capture the flag account: three slots won, about 0.144 α, none
    /// paid
    nonisolated private static func ctfAccount(claimableRao: Int64 = 144_076_980) -> SnLedgerAccountInfo {
        account(noId: ctfNoId, index: 7, finalizedRao: claimableRao, claimableRao: claimableRao, paidRao: 0, kind: .ctf)
    }

    nonisolated private static let ctfPaid = account(noId: ctfNoId, index: 7, finalizedRao: 144_076_980, claimableRao: 0, paidRao: 144_076_980, kind: .ctf)

    /// the capture the flag pool, when the operator could not read it
    nonisolated private static let ctfUnavailable = SnLedgerUnavailablePool(vault: vault2, noId: ctfNoId, kind: .ctf)

    /// an account's row on the tile, before capture the flag
    nonisolated private static func row(_ account: SnLedgerAccountInfo) -> SnLedgerPoolRow {
        SnLedgerPoolRow(name: .pool(noId: account.noId), balance: .account(account))
    }

    /// a view model that has read the ledger once, on a connected coldkey
    private static func loaded(
        _ accounts: [SnLedgerAccountInfo],
        chain: SnLedgerChainInfo = SnLedgerTests.configured
    ) async -> (FakeLedgerClient, EarningsViewModel) {
        let client = FakeLedgerClient()
        client.chain = chain
        client.ledgerAnswer = accounts
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        return (client, viewModel)
    }

    /// lets the claim events the SDK delivered reach the view model, which
    /// applies them on the main actor
    private static func settle(until done: () -> Bool) async {
        for _ in 0..<1000 where !done() {
            await Task.yield()
        }
    }

    private static func snError(code: String, message: String) -> SdkSnError {
        let error = SdkSnError()
        error.code = code
        error.message = message
        return error
    }

    // MARK: the SDK read

    // CL-2: every field of every account, a finalized one with a pending
    // root above it and one only in the pending root
    @Test func theSdkLedgerReadMapsEveryAccount() throws {
        let finalized = SdkSnLedgerAccount()
        finalized.vault = Self.vault2
        finalized.noId = 1
        finalized.index = 42
        finalized.finalizedRao = 5_000_000_000
        finalized.claimableRao = 3_241_000_000
        finalized.paidRao = 1_759_000_000
        finalized.pending = true
        finalized.pendingRao = 5_500_000_000
        let pendingOnly = SdkSnLedgerAccount()
        pendingOnly.vault = Self.vault2
        pendingOnly.noId = 2
        pendingOnly.index = 7
        pendingOnly.pending = true
        pendingOnly.pendingRao = 1_000_000_000
        let list = try #require(SdkSnLedgerAccountList())
        list.add(finalized)
        list.add(pendingOnly)
        let result = SdkSnLedgerAccountsResult()
        result.accounts = list

        // a server that predates kinds: every account is a pool, and no pool
        // is unavailable
        #expect(try EarningsSdkClient.ledgerAccounts(from: result) == SnLedgerAccountsInfo(accounts: [
            Self.account(pending: true, pendingRao: 5_500_000_000),
            Self.account(noId: 2, index: 7, finalizedRao: 0, claimableRao: 0, paidRao: 0, pending: true, pendingRao: 1_000_000_000),
        ]))
    }

    // capture the flag: each account's kind, and each pool the operator could
    // not read, from a partial answer
    @Test func theSdkLedgerReadMapsKindsAndUnavailablePools() throws {
        let pool = SdkSnLedgerAccount()
        pool.vault = Self.vault2
        pool.noId = 1
        pool.kind = SdkSnLedgerPoolKindPool
        pool.label = "Pool 1"
        pool.index = 42
        pool.finalizedRao = 5_000_000_000
        pool.claimableRao = 3_241_000_000
        pool.paidRao = 1_759_000_000
        let ctf = SdkSnLedgerAccount()
        ctf.vault = Self.vault2
        ctf.noId = Self.ctfNoId
        ctf.kind = SdkSnLedgerPoolKindCtf
        ctf.label = "Capture the flag"
        ctf.index = 7
        ctf.finalizedRao = 144_076_980
        ctf.claimableRao = 144_076_980
        let accounts = try #require(SdkSnLedgerAccountList())
        accounts.add(pool)
        accounts.add(ctf)
        let whole = SdkSnLedgerAccountsResult()
        whole.accounts = accounts
        whole.unavailablePools = SdkSnLedgerUnavailablePoolList()
        #expect(try EarningsSdkClient.ledgerAccounts(from: whole) == SnLedgerAccountsInfo(accounts: [Self.account(), Self.ctfAccount()]))

        let unavailable = SdkSnLedgerUnavailablePool()
        unavailable.vault = Self.vault2
        unavailable.noId = Self.ctfNoId
        unavailable.kind = SdkSnLedgerPoolKindCtf
        unavailable.label = "Capture the flag"
        let pools = try #require(SdkSnLedgerUnavailablePoolList())
        pools.add(unavailable)
        let readable = try #require(SdkSnLedgerAccountList())
        readable.add(pool)
        let partial = SdkSnLedgerAccountsResult()
        partial.accounts = readable
        partial.unavailablePools = pools
        partial.partial = true
        #expect(try EarningsSdkClient.ledgerAccounts(from: partial) == SnLedgerAccountsInfo(
            accounts: [Self.account()],
            unavailablePools: [Self.ctfUnavailable]
        ))
    }

    // capture the flag: the sdk's kinds; it reads an entry without one, and a
    // kind it does not know, as a pool
    @Test func theSdkKindsMapToThePoolsKinds() {
        #expect(SnLedgerPoolKind(sdkKind: SdkSnLedgerPoolKindCtf) == .ctf)
        #expect(SnLedgerPoolKind(sdkKind: SdkSnLedgerPoolKindPool) == .pool)
        #expect(SnLedgerPoolKind(sdkKind: "") == .pool)
    }

    // CL-2: ledger_unavailable, or a read with no list, is a failed read and
    // never zero accounts; an empty list is a real answer
    @Test func anUnavailableLedgerReadIsAFailureNotZero() throws {
        let unavailable = SdkSnLedgerAccountsResult()
        unavailable.accounts = SdkSnLedgerAccountList()
        unavailable.error = Self.snError(code: "ledger_unavailable", message: "refused the ledger answer: the answer is for another coldkey")
        #expect(throws: EarningsClientError.message("ledger_unavailable: refused the ledger answer: the answer is for another coldkey")) {
            try EarningsSdkClient.ledgerAccounts(from: unavailable)
        }

        #expect(throws: EarningsClientError.emptyResult) {
            try EarningsSdkClient.ledgerAccounts(from: SdkSnLedgerAccountsResult())
        }

        let none = SdkSnLedgerAccountsResult()
        none.accounts = try #require(SdkSnLedgerAccountList())
        #expect(try EarningsSdkClient.ledgerAccounts(from: none) == SnLedgerAccountsInfo(accounts: []))
    }

    // §11 (v2 claim): the SDK's claim callback becomes claim events; a
    // missing hash or message reads as the v1 bridge reads it
    @Test func theSdkClaimCallbackBecomesClaimEvents() {
        var events: [SnLedgerClaimEvent] = []
        let bridge = SnLedgerClaimCallbackBridge { events.append($0) }

        bridge.sent(1, index: 42, txHash: "0xabc")
        bridge.confirmed(1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000)
        bridge.sent(2, index: 7, txHash: nil)
        bridge.failed(2, index: 7, message: nil)
        bridge.done()

        #expect(events == [
            .sent(noId: 1, index: 42, txHash: "0xabc"),
            .confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000),
            .sent(noId: 2, index: 7, txHash: ""),
            .failed(noId: 2, index: 7, message: "claim_failed"),
            .done,
        ])
    }

    // MARK: the tile

    // CL-2: the account shows with Claim once v2 claims are configured, and
    // without it before activation
    @Test func theTileShowsTheBalancesWithClaimOnlyOnceConfigured() {
        let account = Self.account()
        #expect(SnLedgerTilePresentation.of(load: .loaded([account]), claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([Self.row(account)]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .loaded([account]), claimConfigured: false, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([Self.row(account)]),
            showsClaim: false,
            claimEnabled: false,
            showsPools: false
        ))
    }

    // CL-2: nothing claimable leaves Claim disabled; a v2 claim in flight
    // keeps it, whatever the read says, as it opens the claim's sheet (owner,
    // 2026-11-12: the claim is the session's, and a sheet opened again shows
    // it), as Linux's tile and Windows' section do
    @Test func nothingClaimableDisablesClaimAndAClaimInFlightKeepsIt() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid]), claimConfigured: true, claimInFlight: false)?.claimEnabled == false)
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid]), claimConfigured: true, claimInFlight: true)?.claimEnabled == true)
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account()]), claimConfigured: true, claimInFlight: true)?.claimEnabled == true)
        #expect(SnLedgerTilePresentation.of(load: .unavailable, claimConfigured: true, claimInFlight: true)?.claimEnabled == true)
        // before activation there is no Claim to open it with
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account()]), claimConfigured: false, claimInFlight: true)?.claimEnabled == false)
        // one claimable pool of two is enough
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid, Self.account(noId: 2)]), claimConfigured: true, claimInFlight: false)?.claimEnabled == true)
    }

    // CL-2: a ledger that cannot be read is "Unavailable" with Claim
    // disabled, never 0; before activation it is no tile at all
    @Test func anUnreadableLedgerIsUnavailableNeverZero() {
        #expect(SnLedgerTilePresentation.of(load: .unavailable, claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .unavailable,
            showsClaim: true,
            claimEnabled: false,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .unavailable, claimConfigured: false, claimInFlight: false) == nil)
    }

    // CL-2: no account, or no read yet, is no tile
    @Test func noAccountOrNoReadYetIsNoTile() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([]), claimConfigured: true, claimInFlight: false) == nil)
        #expect(SnLedgerTilePresentation.of(load: .loaded([]), claimConfigured: false, claimInFlight: false) == nil)
        #expect(SnLedgerTilePresentation.of(load: .loading, claimConfigured: true, claimInFlight: false) == nil)
    }

    // CL-2: with more than one pool each account names its pool, "Pool 1",
    // and Claim is never "Claim both" without capture the flag
    @Test func severalPoolsNameTheirPool() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account()]), claimConfigured: true, claimInFlight: false)?.showsPools == false)
        let second = Self.account(noId: 2, index: 3)
        let tile = SnLedgerTilePresentation.of(load: .loaded([Self.account(), second]), claimConfigured: true, claimInFlight: false)
        #expect(tile == SnLedgerTilePresentation(
            balances: .pools([Self.row(Self.account()), Self.row(second)]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: true,
            claimsBoth: false
        ))
    }

    // CL-2: a pending root shows what it adds to the finalized amount, as
    // pending, in the app's alpha format
    @Test func aPendingRootShowsWhatItAddsAsPending() {
        #expect(Self.account(pending: true, pendingRao: 5_500_000_000).pendingIncreaseRao == 500_000_000)
        #expect(SnAlpha.format(rao: 500_000_000) == "0.5000 SN25α")
        // only in the pending root: all of it is pending, nothing claimable
        #expect(Self.account(finalizedRao: 0, claimableRao: 0, paidRao: 0, pending: true, pendingRao: 1_000_000_000).pendingIncreaseRao == 1_000_000_000)
        // a pending root that adds nothing, or none at all
        #expect(Self.account(pending: true, pendingRao: 5_000_000_000).pendingIncreaseRao == nil)
        #expect(Self.account(pending: true, pendingRao: 4_000_000_000).pendingIncreaseRao == nil)
        #expect(Self.account().pendingIncreaseRao == nil)
    }

    // MARK: the read on the screen

    // CL-2: the refresh reads the v2 accounts and vault2 beside the v1
    // claims, which keep their own total
    @Test func theRefreshReadsTheLedgerBesideTheV1Claims() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        client.v1Claims = [
            SnEpochClaimInfo(epoch: 8, shareBps: 71, amountRao: 1_000_000_000, status: .claimable, claimOpenBlock: 0, expiryBlock: 0, txHash: ""),
        ]
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.ledger == .loaded([Self.account()]))
        #expect(viewModel.ledgerChain == Self.configured)
        #expect(viewModel.ledgerTile?.claimEnabled == true)
        #expect(viewModel.ledgerClaimableRao == 3_241_000_000)
        #expect(viewModel.totalClaimableRao == 1_000_000_000)
        #expect(viewModel.claimableClaims.map(\.epoch) == [8])
    }

    // CL-2: a failed read is unavailable; a later read shows the accounts;
    // a failure after that is unavailable again, so no claim is offered on
    // balances that could not be read
    @Test func aFailedLedgerReadIsUnavailableNeverZero() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = nil
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.ledger == .unavailable)
        #expect(viewModel.ledgerTile?.balances == .unavailable)
        #expect(viewModel.ledgerTile?.claimEnabled == false)

        client.ledgerAnswer = [Self.account()]
        await viewModel.refresh()
        #expect(viewModel.ledger == .loaded([Self.account()]))

        client.ledgerAnswer = nil
        await viewModel.refresh()
        #expect(viewModel.ledger == .unavailable)
        #expect(!viewModel.ledgerClaimEnabled)
        #expect(client.ledgerReads == 3)
    }

    // CL-2: without a coldkey the ledger is not read and there is no tile
    @Test func withoutAColdkeyThereIsNoV2Tile() async {
        let client = FakeLedgerClient()
        client.wallet = nil
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.ledger == .loaded([]))
        #expect(viewModel.ledgerTile == nil)
        #expect(client.ledgerReads == 0)
    }

    // MARK: the claim

    // §11 (v2 claim): Claim needs v2 claims configured and something
    // claimable, and runs one claim at a time
    @Test func aClaimNeedsConfiguredClaimsAndSomethingClaimable() async {
        let (unconfiguredClient, unconfigured) = await Self.loaded([Self.account()], chain: .unconfigured)
        #expect(unconfigured.ledgerTile?.showsClaim == false)
        #expect(!unconfigured.ledgerClaimEnabled)
        unconfigured.claimLedger()
        #expect(unconfiguredClient.claimCalls == 0)
        #expect(!unconfigured.isLedgerClaiming)

        let (paidClient, paid) = await Self.loaded([Self.paid])
        #expect(!paid.ledgerClaimEnabled)
        paid.claimLedger()
        #expect(paidClient.claimCalls == 0)

        let (client, viewModel) = await Self.loaded([Self.account()])
        #expect(viewModel.ledgerClaimEnabled)
        viewModel.claimLedger()
        viewModel.claimLedger()
        #expect(client.claimCalls == 1)
        #expect(client.v1ClaimCalls == 0)
    }

    // §11 (v2 claim): Sent shows the transaction on the explorer, Confirmed
    // the amount the vault paid, and after Done the accounts are read again
    @Test func aClaimShowsSentWithItsLinkThenConfirmedWithTheAmount() async {
        let (client, viewModel) = await Self.loaded([Self.account()])
        let link = URL(string: "https://evm.taostats.io/tx/0xabc")

        viewModel.claimLedger()
        #expect(viewModel.isLedgerClaiming)
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.pending])
        // the tile's Claim opens the claim in flight, whose own Claim waits
        #expect(viewModel.ledgerTile?.claimEnabled == true)
        #expect(!viewModel.ledgerClaimEnabled)

        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        await Self.settle { viewModel.ledgerClaimProgress[Self.key] == .sent(txHash: "0xabc") }
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .pool(noId: 1), amountRao: 3_241_000_000, status: .sent, explorerUrl: link),
        ])

        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_240_999_999))
        await Self.settle { viewModel.ledgerClaimProgress[Self.key] == .confirmed(txHash: "0xabc", amountRao: 3_240_999_999) }
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .pool(noId: 1), amountRao: 3_240_999_999, status: .claimed, explorerUrl: link),
        ])
        #expect(!viewModel.ledgerClaimFinished)

        client.ledgerAnswer = [Self.paid]
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid]) }
        #expect(!viewModel.isLedgerClaiming)
        #expect(viewModel.ledgerClaimFinished)
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(client.ledgerReads == 2)
        // the confirmed line stays until the dialog is done
        #expect(viewModel.ledgerClaimRows.map(\.amountRao) == [3_240_999_999])

        viewModel.resetLedgerClaimProgress()
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .pool(noId: 1), amountRao: 0, status: .claimed, explorerUrl: nil),
        ])
    }

    // §11 (v2 claim), sdk-ctf-v2 §2.1: needs_gas means the sdk sent nothing
    // for the account, so it is still claimable: no failure, the gas card's
    // top-up, and Claim off until the dialog starts over
    @Test func needsGasShowsTheGasTopUp() async {
        let (client, viewModel) = await Self.loaded([Self.account()])
        #expect(!viewModel.ledgerNeedsGas)

        viewModel.claimLedger()
        client.emit(.failed(noId: 1, index: 42, message: "needs_gas: this claim needs up to 0.0126 TAO of gas; send TAO to the gas key"))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }

        #expect(viewModel.ledgerClaimProgress == [Self.key: .needsGas])
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.unclaimed])
        #expect(viewModel.ledgerClaimRows.map(\.amountRao) == [3_241_000_000])
        #expect(viewModel.ledgerNeedsGas)
        #expect(!viewModel.ledgerClaimEnabled)
        #expect(viewModel.ledgerClaimFinished)

        viewModel.resetLedgerClaimProgress()
        #expect(!viewModel.ledgerNeedsGas)
    }

    // sdk-ctf-v2 §2.1 (owner, 2026-11-11: claim the largest if there is not
    // enough gas for both): a gas key that can pay for one claim but not the
    // batch claims the largest account alone; the other, which the sdk sent
    // nothing for, is still claimable with the top-up, never a failure
    @Test func withGasForOneClaimTheOtherAccountIsStillClaimable() async {
        let (client, viewModel) = await Self.loaded([Self.account(), Self.ctfAccount()])
        #expect(viewModel.ledgerClaimsBoth)

        viewModel.claimLedger()
        #expect(client.claimCalls == 1)
        client.emit(.sent(noId: 1, index: 42, txHash: "0xlargest"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xlargest", amountRao: 3_241_000_000))
        client.emit(.failed(noId: Self.ctfNoId, index: 7, message: "needs_gas: this claim needs up to 0.0143 TAO of gas, the gas key 0x1111 has 0.0021 TAO; send TAO to 5Grw"))
        client.ledgerAnswer = [Self.paid, Self.ctfAccount()]
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid, Self.ctfAccount()]) }

        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .providerPool, amountRao: 3_241_000_000, status: .claimed, explorerUrl: URL(string: "https://evm.taostats.io/tx/0xlargest")),
            SnLedgerClaimRow(id: Self.ctfKey, name: .captureTheFlag, amountRao: 144_076_980, status: .unclaimed, explorerUrl: nil),
        ])
        #expect(viewModel.ledgerNeedsGas)
        #expect(viewModel.ledgerClaimFinished)

        // the dialog done, the account claims once the gas key is topped up
        viewModel.resetLedgerClaimProgress()
        #expect(!viewModel.ledgerNeedsGas)
        #expect(viewModel.ledgerClaimableAccounts == [Self.ctfAccount()])
        #expect(viewModel.ledgerClaimEnabled)
    }

    // §11 (v2 claim): a gas key short of a v2 claim's reserve shows the
    // top-up before any claim, as the v1 dialog does
    @Test func aShortGasKeyShowsTheTopUpBeforeAClaim() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        client.gasTao = 0.012
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.ledgerGasNeededTao == EarningsViewModel.ledgerGasTaoPerClaim)
        #expect(viewModel.ledgerNeedsGas)
        #expect(!viewModel.ledgerClaimEnabled)

        client.gasTao = EarningsViewModel.ledgerGasTaoPerClaim
        await viewModel.refresh()
        #expect(!viewModel.ledgerNeedsGas)
        #expect(viewModel.ledgerClaimEnabled)
    }

    // §11 (v2 claim): already_claimed (another sender claimed first) is
    // success, not a failure, and the accounts are read again
    @Test func alreadyClaimedIsSuccessAndRefreshes() async {
        let (client, viewModel) = await Self.loaded([Self.account()])

        viewModel.claimLedger()
        client.emit(.failed(noId: 1, index: 42, message: "already_claimed: NothingToClaim"))
        client.ledgerAnswer = [Self.paid]
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid]) }

        #expect(viewModel.ledgerClaimProgress == [Self.key: .alreadyClaimed])
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed])
        #expect(!viewModel.ledgerNeedsGas)
        #expect(client.ledgerReads == 2)
    }

    // §11 (v2 claim): any other failure is listed in the SDK's words; an
    // account the SDK never reached is not left pending
    @Test func otherFailuresAreListedAndNoAccountIsLeftPending() async {
        let (client, viewModel) = await Self.loaded([Self.account(), Self.account(noId: 2, index: 3)])
        let second = SnLedgerAccountKey(noId: 2, index: 3)
        let mismatch = "proof_mismatch: the proof does not verify against roots(1, 3)"

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued, second: .queued])
        client.emit(.failed(noId: 1, index: 42, message: mismatch))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }

        #expect(viewModel.ledgerClaimProgress == [Self.key: .failed(message: mismatch)])
        #expect(viewModel.ledgerClaimFailures.map(\.key) == [Self.key])
        #expect(viewModel.ledgerClaimFailures.map(\.failure) == [.message(mismatch)])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.failed, .unclaimed])
        #expect(viewModel.ledgerClaimFinished)
    }

    // §11 (v2 claim): a failure that names no account (no device) is listed
    // in the v1 claim's words
    @Test func aFailureNamingNoAccountIsListed() async {
        let (client, viewModel) = await Self.loaded([Self.account()])

        viewModel.claimLedger()
        client.emit(.failed(noId: 0, index: 0, message: "local_state_unavailable"))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }

        #expect(viewModel.ledgerClaimFailures.map(\.failure) == [.connectWallet])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.unclaimed])
        #expect(viewModel.ledgerClaimFinished)
    }

    // §11 (v2 claim): each failure code reads as the v1 claim reads it;
    // anything else as the SDK wrote it
    @Test func failuresReadAsTheV1ClaimReadsThem() {
        #expect(SnLedgerClaimFailure.of("needs_gas: the gas key has no TAO") == .needsGas)
        #expect(SnLedgerClaimFailure.of("chain_rpc_unreachable: dial tcp: i/o timeout") == .unreachable)
        #expect(SnLedgerClaimFailure.of("chain_not_configured: vault2 address: not set") == .unreachable)
        #expect(SnLedgerClaimFailure.of("ledger_unavailable: 503 Service Unavailable") == .unreachable)
        #expect(SnLedgerClaimFailure.of("artifact_unavailable: 404") == .unreachable)
        #expect(SnLedgerClaimFailure.of("connect_wallet_first: connect a Bittensor wallet first") == .connectWallet)
        #expect(SnLedgerClaimFailure.of("local_state_unavailable") == .connectWallet)
        #expect(SnLedgerClaimFailure.of("not_claimable: AmountTooLow") == .message("not_claimable: AmountTooLow"))
        #expect(SnLedgerClaimFailure.of("claim_failed: TooManyStakingHotkeys") == .message("claim_failed: TooManyStakingHotkeys"))
        #expect(SnLedgerClaimFailure.code(of: "already_claimed: NothingToClaim") == SnLedgerClaimFailure.alreadyClaimedCode)
    }

    // §11 (v2 claim): before a claim each pool's line says what the ledger
    // says; a claim's progress overrides it
    @Test func eachPoolLineSaysWhatTheLedgerSays() {
        #expect(SnLedgerClaimRow.of(Self.account(), progress: nil, chain: Self.configured) == SnLedgerClaimRow(
            id: Self.key,
            name: .pool(noId: 1),
            amountRao: 3_241_000_000,
            status: .unclaimed,
            explorerUrl: nil
        ))
        #expect(SnLedgerClaimRow.of(Self.paid, progress: nil, chain: Self.configured).status == .claimed)
        let pendingOnly = Self.account(finalizedRao: 0, claimableRao: 0, paidRao: 0, pending: true, pendingRao: 1_000_000_000)
        #expect(SnLedgerClaimRow.of(pendingOnly, progress: nil, chain: Self.configured).status == .pending)
        #expect(SnLedgerClaimRow.of(Self.account(), progress: .queued, chain: Self.configured).status == .pending)
        #expect(SnLedgerClaimRow.of(Self.account(), progress: .alreadyClaimed, chain: Self.configured).status == .claimed)
        #expect(SnLedgerClaimRow.of(Self.account(), progress: .failed(message: "claim_failed: reverted"), chain: Self.configured).status == .failed)
        // no explorer link without one configured
        #expect(SnLedgerClaimRow.of(Self.account(), progress: .sent(txHash: "0xabc"), chain: .unconfigured).explorerUrl == nil)
    }

    // §11 (v2 claim): the explorer link is rendered as the SDK's
    // ExplorerUrlForTx renders it
    @Test func theExplorerLinkIsRenderedAsTheSdkRendersIt() {
        #expect(Self.configured.explorerUrl(txHash: "0xabc") == URL(string: "https://evm.taostats.io/tx/0xabc"))
        #expect(SnLedgerChainInfo(vault2Address: Self.vault2, explorerTxUrl: "https://explorer.test/tx/").explorerUrl(txHash: "0xabc") == URL(string: "https://explorer.test/tx/0xabc"))
        #expect(SnLedgerChainInfo(vault2Address: Self.vault2, explorerTxUrl: "https://explorer.test/tx").explorerUrl(txHash: "0xabc") == URL(string: "https://explorer.test/tx/0xabc"))
        #expect(SnLedgerChainInfo(vault2Address: Self.vault2, explorerTxUrl: "").explorerUrl(txHash: "0xabc") == nil)
        #expect(Self.configured.explorerUrl(txHash: "") == nil)
        #expect(Self.configured.claimConfigured)
        #expect(!SnLedgerChainInfo.unconfigured.claimConfigured)
    }

    // MARK: capture the flag

    // §10: each row is named from its kind: a capture the flag account
    // "Capture the flag", the one operator pool beside one "Provider pool",
    // and a pool with none beside it its number, as before
    @Test func eachPoolIsNamedFromItsKind() {
        #expect(SnLedgerPoolName.of(kind: .pool, noId: 1, namesProviderPool: false) == .pool(noId: 1))
        #expect(SnLedgerPoolName.of(kind: .pool, noId: 1, namesProviderPool: true) == .providerPool)
        #expect(SnLedgerPoolName.of(kind: .ctf, noId: Self.ctfNoId, namesProviderPool: true) == .captureTheFlag)
        #expect(SnLedgerPoolName.of(kind: .ctf, noId: Self.ctfNoId, namesProviderPool: false) == .captureTheFlag)
        // a pool the operator could not read counts as beside
        let pools = SnLedgerPools(accounts: [Self.account()], unavailablePools: [Self.ctfUnavailable])
        #expect(pools.namesProviderPool)
        #expect(pools.name(Self.account()) == .providerPool)
        #expect(pools.name(Self.ctfUnavailable) == .captureTheFlag)
        #expect(!SnLedgerPools(accounts: [Self.account(), Self.account(noId: 2, index: 3)], unavailablePools: []).namesProviderPool)
        #expect(!SnLedgerPools(accounts: [Self.account()], unavailablePools: []).namesProviderPool)
    }

    // §10, as Android's snLedgerPoolName and Linux's LedgerPoolName: beside
    // two operator pools "Provider pool" would name neither, so each keeps
    // its number, read or not; the capture the flag pool keeps its name
    @Test func twoOperatorPoolsBesideCaptureTheFlagKeepTheirNumbers() {
        let second = Self.account(noId: 2, index: 3)
        let pools = SnLedgerPools(accounts: [Self.account(), second, Self.ctfAccount()], unavailablePools: [])
        #expect(!pools.namesProviderPool)
        #expect(pools.rows.map(\.name) == [.pool(noId: 1), .pool(noId: 2), .captureTheFlag])
        let unreadSecond = SnLedgerPools(
            accounts: [Self.account(), Self.ctfAccount()],
            unavailablePools: [SnLedgerUnavailablePool(vault: Self.vault2, noId: 2)]
        )
        #expect(unreadSecond.rows.map(\.name) == [.pool(noId: 1), .captureTheFlag, .pool(noId: 2)])
        // the relay's rows the same
        let coldkey = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        let status = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 2, claimableRao: 1_000_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: 144_076_980),
            ]
        )
        #expect(SnClaimRelayRow.rows(status).map(\.name) == [.pool(noId: 1), .pool(noId: 2), .captureTheFlag])
        // a second pool's account with no row is in view all the same
        let rowless = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 2),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: 144_076_980),
            ]
        )
        #expect(SnClaimRelayRow.rows(rowless).map(\.name) == [.pool(noId: 1), .captureTheFlag])
        // one operator pool's accounts of two coldkeys are still one pool
        let replaced = "5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty"
        let twoColdkeys = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 1, claimableRao: 1_000_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: 144_076_980),
            ]
        )
        #expect(SnClaimRelayRow.rows(twoColdkeys).map(\.name) == [.providerPool, .providerPool, .captureTheFlag])
    }

    // §10: the capture the flag account is a row of its own under the
    // provider pool's, both named, and Claim claims both
    @Test func aCaptureTheFlagAccountIsARowOfItsOwn() {
        let pool = Self.account()
        let ctf = Self.ctfAccount()
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, ctf]), claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([
                SnLedgerPoolRow(name: .providerPool, balance: .account(pool)),
                SnLedgerPoolRow(name: .captureTheFlag, balance: .account(ctf)),
            ]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: true,
            claimsBoth: true
        ))
        // alone, it is named all the same
        #expect(SnLedgerTilePresentation.of(load: .loaded([ctf]), claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([SnLedgerPoolRow(name: .captureTheFlag, balance: .account(ctf))]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: true
        ))
        // both, but only one has something to claim: Claim
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid, ctf]), claimConfigured: true, claimInFlight: false)?.claimsBoth == false)
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, Self.ctfPaid]), claimConfigured: true, claimInFlight: false)?.claimsBoth == false)
    }

    // §9.1, §10: a pool the operator could not read is "Unavailable right
    // now" in its own row, never 0, and hides no other: the others claim as
    // usual
    @Test func anUnavailablePoolHidesNoOther() {
        let pool = Self.account()
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool], unavailablePools: [Self.ctfUnavailable]), claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([
                SnLedgerPoolRow(name: .providerPool, balance: .account(pool)),
                SnLedgerPoolRow(name: .captureTheFlag, balance: .unavailable(Self.ctfUnavailable)),
            ]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: true,
            claimsBoth: false
        ))
        // the provider pool unavailable: the capture the flag account claims
        let providerPool = SnLedgerUnavailablePool(vault: Self.vault2, noId: 1)
        let ctf = Self.ctfAccount()
        #expect(SnLedgerTilePresentation.of(load: .loaded([ctf], unavailablePools: [providerPool]), claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([
                SnLedgerPoolRow(name: .captureTheFlag, balance: .account(ctf)),
                SnLedgerPoolRow(name: .providerPool, balance: .unavailable(providerPool)),
            ]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: true
        ))
        // nothing read but a pool that could not be: its row once v2 claims
        // are configured, and no tile before, as for a ledger that cannot be
        // read
        #expect(SnLedgerTilePresentation.of(load: .loaded([], unavailablePools: [providerPool]), claimConfigured: true, claimInFlight: false) == SnLedgerTilePresentation(
            balances: .pools([SnLedgerPoolRow(name: .pool(noId: 1), balance: .unavailable(providerPool))]),
            showsClaim: true,
            claimEnabled: false,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .loaded([], unavailablePools: [providerPool]), claimConfigured: false, claimInFlight: false) == nil)
    }

    // §10: a balance under the relay's transfer floor waits, "Below the claim
    // minimum", and Claim is not "Claim both"; without a floor the claim's
    // preflight decides
    @Test func aBalanceUnderTheFloorWaitsBesideCaptureTheFlag() {
        let pool = Self.account()
        let oneSlot = Self.ctfAccount(claimableRao: 48_025_660)
        let tile = SnLedgerTilePresentation.of(load: .loaded([pool, oneSlot]), claimConfigured: true, claimInFlight: false, transferFloorRao: Self.floorRao)
        #expect(tile?.balances == .pools([
            SnLedgerPoolRow(name: .providerPool, balance: .account(pool)),
            SnLedgerPoolRow(name: .captureTheFlag, balance: .account(oneSlot), underFloor: true),
        ]))
        #expect(tile?.claimEnabled == true)
        #expect(tile?.claimsBoth == false)
        // nothing else to claim: no claim
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid, oneSlot]), claimConfigured: true, claimInFlight: false, transferFloorRao: Self.floorRao)?.claimEnabled == false)
        // the floor or more: both
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, Self.ctfAccount(claimableRao: Self.floorRao)]), claimConfigured: true, claimInFlight: false, transferFloorRao: Self.floorRao)?.claimsBoth == true)
        // no floor without a price
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, oneSlot]), claimConfigured: true, claimInFlight: false, transferFloorRao: 0)?.claimsBoth == true)
        // beside a pool that could not be read it waits too
        let smallPool = Self.account(claimableRao: 1_000_000)
        let beside = SnLedgerPools(accounts: [smallPool, oneSlot], unavailablePools: [], transferFloorRao: Self.floorRao)
        #expect(SnLedgerClaimRow.of(smallPool, progress: nil, chain: Self.configured, pools: beside).status == .underFloor)
        #expect(SnLedgerClaimRow.of(oneSlot, progress: nil, chain: Self.configured, pools: beside).status == .underFloor)
        let partial = SnLedgerPools(accounts: [smallPool], unavailablePools: [SnLedgerUnavailablePool(vault: Self.vault2, noId: 2)], transferFloorRao: Self.floorRao)
        #expect(SnLedgerClaimRow.of(smallPool, progress: nil, chain: Self.configured, pools: partial).status == .underFloor)
        // a claim's progress overrides it
        #expect(SnLedgerClaimRow.of(oneSlot, progress: .underFloor, chain: Self.configured, pools: beside).status == .underFloor)
        #expect(SnLedgerClaimRow.of(oneSlot, progress: .sent(txHash: "0xabc"), chain: Self.configured, pools: beside).status == .sent)
    }

    // owner, 2026-11-11: "Below the claim minimum" shows on any pool account
    // under the minimum, lone or beside others, on a server with capture the
    // flag or before it, and the claim never asks the chain for a transfer it
    // refuses: a lone account under the floor offers no Claim
    @Test func aLonePoolAccountUnderTheFloorWaitsToo() async {
        let smallPool = Self.account(claimableRao: 1_000_000)
        #expect(SnLedgerTilePresentation.of(load: .loaded([smallPool]), claimConfigured: true, claimInFlight: false, transferFloorRao: Self.floorRao) == SnLedgerTilePresentation(
            balances: .pools([SnLedgerPoolRow(name: .pool(noId: 1), balance: .account(smallPool), underFloor: true)]),
            showsClaim: true,
            claimEnabled: false,
            showsPools: false
        ))
        let lone = SnLedgerPools(accounts: [smallPool], unavailablePools: [], transferFloorRao: Self.floorRao)
        #expect(SnLedgerClaimRow.of(smallPool, progress: nil, chain: Self.configured, pools: lone).status == .underFloor)
        #expect(!lone.claimable(smallPool))
        // two operator pools, neither capture the flag's
        let twoPools = SnLedgerTilePresentation.of(
            load: .loaded([Self.account(), Self.account(noId: 2, index: 3, claimableRao: 1_000_000)]),
            claimConfigured: true,
            claimInFlight: false,
            transferFloorRao: Self.floorRao
        )
        #expect(twoPools?.balances == .pools([
            SnLedgerPoolRow(name: .pool(noId: 1), balance: .account(Self.account())),
            SnLedgerPoolRow(name: .pool(noId: 2), balance: .account(Self.account(noId: 2, index: 3, claimableRao: 1_000_000)), underFloor: true),
        ]))
        #expect(twoPools?.claimEnabled == true)
        // at the floor it is claimable; without a floor the preflight decides
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account(claimableRao: Self.floorRao)]), claimConfigured: true, claimInFlight: false, transferFloorRao: Self.floorRao)?.claimEnabled == true)
        #expect(SnLedgerTilePresentation.of(load: .loaded([smallPool]), claimConfigured: true, claimInFlight: false, transferFloorRao: 0)?.claimEnabled == true)

        // the screen: the relay's floor holds the lone account, and its claim
        // is not offered
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [smallPool]
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.ledgerTile?.balances == .pools([SnLedgerPoolRow(name: .pool(noId: 1), balance: .account(smallPool), underFloor: true)]))
        #expect(viewModel.ledgerClaimableAccounts.isEmpty)
        #expect(viewModel.ledgerClaimableRao == 0)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.underFloor])
        #expect(!viewModel.ledgerClaimEnabled)
        viewModel.claimLedger()
        #expect(client.claimCalls == 0)
    }

    // §10: the sdk claims every account with something to claim, and its
    // preflight finds one under the floor (not_claimable: AmountTooLow) and
    // sends nothing for it: it waits, below the claim minimum, and is no
    // failure, whether the sheet left it out by the relay's floor or knew no
    // floor, beside capture the flag or alone (owner, 2026-11-11)
    @Test func theClaimsRefusalUnderTheFloorIsNoFailure() async {
        let amountTooLow = "not_claimable: AmountTooLow: the claim is below the runtime's transfer floor"
        let oneSlot = Self.ctfAccount(claimableRao: 48_025_660)

        // left out by the relay's floor
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), oneSlot]
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued])
        client.emit(.failed(noId: Self.ctfNoId, index: 7, message: amountTooLow))
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }
        #expect(viewModel.ledgerClaimProgress[Self.ctfKey] == .underFloor)
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, .underFloor])

        // no floor known: queued, then refused
        let (unpriced, unpricedModel) = await Self.loaded([Self.account(), oneSlot])
        #expect(unpricedModel.ledgerClaimsBoth)
        unpricedModel.claimLedger()
        unpriced.emit(.failed(noId: Self.ctfNoId, index: 7, message: amountTooLow))
        unpriced.emit(.done)
        await Self.settle { !unpricedModel.isLedgerClaiming }
        #expect(unpricedModel.ledgerClaimFailures.isEmpty)
        #expect(unpricedModel.ledgerClaimProgress[Self.ctfKey] == .underFloor)

        // a lone pool account, on a server before capture the flag, with no
        // floor known: no failure either
        let small = Self.account(claimableRao: 1_000_000)
        let (loneClient, loneModel) = await Self.loaded([small])
        loneModel.claimLedger()
        loneClient.emit(.failed(noId: 1, index: 42, message: amountTooLow))
        loneClient.emit(.done)
        await Self.settle { !loneModel.isLedgerClaiming }
        #expect(loneModel.ledgerClaimFailures.isEmpty)
        #expect(loneModel.ledgerClaimRows.map(\.status) == [.underFloor])
        // any other not_claimable is still a failure
        let (otherClient, otherModel) = await Self.loaded([Self.account()])
        let elsewhere = "not_claimable: the ledger lists this account in 0x3333333333333333333333333333333333333333, not in the configured vault2 0x2222222222222222222222222222222222222222"
        otherModel.claimLedger()
        otherClient.emit(.failed(noId: 1, index: 42, message: elsewhere))
        otherClient.emit(.done)
        await Self.settle { !otherModel.isLedgerClaiming }
        #expect(otherModel.ledgerClaimFailures.map(\.failure) == [.message(elsewhere)])
        #expect(otherModel.ledgerClaimRows.map(\.status) == [.failed])
    }

    // §9.1: the claim sheet shows no amount, never 0, while nothing could be
    // read: the ledger, or every pool of an answer that read no account
    @Test func theClaimSheetHasNoAmountWhileNothingCouldBeRead() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = []
        client.unavailablePools = [Self.ctfUnavailable]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimUnavailable)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.unavailable])

        client.ledgerAnswer = [Self.account()]
        await viewModel.refresh()
        #expect(!viewModel.ledgerClaimUnavailable)

        client.ledgerAnswer = nil
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimUnavailable)
    }

    // as Windows' and Android's claim dialogs: the sheet's figure, the
    // claim's total, shows while a line holds an amount above the floor a
    // claim moves, or nothing is left at all (a true 0); while what is left
    // is all under the floor, in a pool that could not be read or of an
    // amount not known yet, the lines say why and there is no figure, never
    // "Claimable 0"
    @Test func theClaimSheetHasNoFigureWhileNothingAboveTheFloorIsLeft() async {
        // a lone account under the floor
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(claimableRao: 1_000_000)]
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimRowsLeft == [.noFigure])
        #expect(viewModel.ledgerClaimableRao == 0)
        #expect(!viewModel.ledgerClaimUnavailable)
        #expect(!viewModel.ledgerClaimTotalKnown)

        // above the floor beside one under it: the figure is what the claim moves
        let oneSlot = Self.ctfAccount(claimableRao: 48_025_660)
        client.ledgerAnswer = [Self.account(), oneSlot]
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimRowsLeft == [.moves, .noFigure])
        #expect(viewModel.ledgerClaimTotalKnown)
        #expect(viewModel.ledgerClaimableRao == 3_241_000_000)

        // the claim pays the one above it, and the one under the floor is all
        // that is left
        viewModel.claimLedger()
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        #expect(viewModel.ledgerClaimTotalKnown)
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        client.ledgerAnswer = [Self.paid, oneSlot]
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid, oneSlot]) }
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, .underFloor])
        #expect(viewModel.ledgerClaimRowsLeft == [.nothing, .noFigure])
        #expect(!viewModel.ledgerClaimTotalKnown)

        // nothing left to claim beside a pool that could not be read
        viewModel.resetLedgerClaimProgress()
        client.ledgerAnswer = [Self.paid]
        client.unavailablePools = [Self.ctfUnavailable]
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimRowsLeft == [.nothing, .noFigure])
        #expect(!viewModel.ledgerClaimUnavailable)
        #expect(!viewModel.ledgerClaimTotalKnown)

        // nothing left at all: a true 0
        client.unavailablePools = []
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimRowsLeft == [.nothing])
        #expect(viewModel.ledgerClaimTotalKnown)
        #expect(viewModel.ledgerClaimableRao == 0)

        // an account the claim found in a pool the sheet could not read, of an
        // amount not known yet, and nothing else left
        let found = FakeLedgerClient()
        found.chain = Self.configured
        found.ledgerAnswer = [Self.account()]
        found.unavailablePools = [Self.ctfUnavailable]
        let foundModel = EarningsViewModel(client: found)
        await foundModel.refresh()
        foundModel.claimLedger()
        found.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        found.emit(.failed(noId: Self.ctfNoId, index: 7, message: "claim_failed: execution reverted"))
        await Self.settle { foundModel.ledgerClaimProgress[Self.ctfKey] != nil }
        #expect(foundModel.ledgerClaimRows.map(\.status) == [.claimed, .failed])
        #expect(foundModel.ledgerClaimRowsLeft == [.nothing, .noFigure])
        // while the claim runs its figure is what it moves (every app,
        // 2026-11-12); once it is over the lines left say why, with no figure
        #expect(foundModel.ledgerClaimTotalKnown)
        #expect(foundModel.ledgerClaimFigureRao == 3_241_000_000)
        found.emit(.done)
        await Self.settle { !foundModel.isLedgerClaiming }
        #expect(foundModel.ledgerClaimRowsLeft == [.nothing, .noFigure])
        #expect(!foundModel.ledgerClaimTotalKnown)
    }

    // the sdk claims every account with something to claim, one the sheet
    // put under the relay's floor too: whatever it then says of it (needs_gas
    // with the gas key's top-up, a failure, sent and then failed), the line
    // shows that, and is no figure the claim moves, which never takes it; with
    // nothing else left the sheet shows no figure, never "Claimable 0" beside
    // the line
    @Test func anAccountUnderTheFloorTheSdkTriesIsNoFigure() async {
        let oneSlot = Self.ctfAccount(claimableRao: 48_025_660)
        let answers: [(name: String, events: [SnLedgerClaimEvent], status: SnLedgerClaimStatus)] = [
            ("needs_gas", [.failed(noId: Self.ctfNoId, index: 7, message: "needs_gas: the gas key cannot pay for the claim")], .unclaimed),
            ("a failure", [.failed(noId: Self.ctfNoId, index: 7, message: "claim_failed: execution reverted")], .failed),
            ("sent, then failed", [
                .sent(noId: Self.ctfNoId, index: 7, txHash: "0xalone"),
                .failed(noId: Self.ctfNoId, index: 7, message: "claim_failed: execution reverted"),
            ], .failed),
        ]
        for answer in answers {
            let client = FakeLedgerClient()
            client.chain = Self.configured
            client.ledgerAnswer = [Self.account(), oneSlot]
            client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
            let viewModel = EarningsViewModel(client: client)
            await viewModel.refresh()
            viewModel.claimLedger()
            #expect(viewModel.ledgerClaimProgress == [Self.key: .queued], "\(answer.name)")
            client.emit(.sent(noId: 1, index: 42, txHash: "0xlargest"))
            client.emit(.confirmed(noId: 1, index: 42, txHash: "0xlargest", amountRao: 3_241_000_000))
            for event in answer.events {
                client.emit(event)
            }
            client.ledgerAnswer = [Self.paid, oneSlot]
            client.emit(.done)
            await Self.settle { viewModel.ledger == .loaded([Self.paid, oneSlot]) }
            #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, answer.status], "\(answer.name)")
            #expect(viewModel.ledgerClaimRows.last?.amountRao == 48_025_660, "\(answer.name)")
            #expect(viewModel.ledgerClaimRowsLeft == [.nothing, .noFigure], "\(answer.name)")
            #expect(viewModel.ledgerClaimableRao == 0, "\(answer.name)")
            #expect(!viewModel.ledgerClaimTotalKnown, "\(answer.name)")
            #expect(!viewModel.ledgerClaimEnabled, "\(answer.name)")
        }
    }

    // §10: the floor is the relay's while it answers; the claim pays, and its
    // total and its button count, only what the floor lets through
    @Test func theRelaysFloorKeepsACaptureTheFlagBalanceOutOfTheClaim() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount(claimableRao: 48_025_660)]
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()

        #expect(viewModel.ledgerTransferFloorRao == Self.floorRao)
        #expect(viewModel.ledgerClaimableAccounts == [Self.account()])
        #expect(viewModel.ledgerClaimableRao == 3_241_000_000)
        #expect(!viewModel.ledgerClaimsBoth)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.unclaimed, .underFloor])
        #expect(viewModel.ledgerTile?.claimsBoth == false)

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued])

        // an unanswered relay gives no floor
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao, unavailable: true)
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTransferFloorRao == 0)
    }

    // §10: one claim claims both pools, as the SDK's one batch transaction:
    // both lines are sent with the same transaction and confirmed with what
    // vault2 paid each; "Claim both" needs only one claim's gas reserve
    @Test func oneClaimClaimsBothPools() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.gasTao = EarningsViewModel.ledgerGasTaoPerClaim
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        let link = URL(string: "https://evm.taostats.io/tx/0xbatch")

        #expect(viewModel.ledgerClaimsBoth)
        #expect(viewModel.ledgerTile?.claimsBoth == true)
        #expect(viewModel.ledgerClaimableRao == 3_241_000_000 + 144_076_980)
        #expect(viewModel.ledgerGasNeededTao == EarningsViewModel.ledgerGasTaoPerClaim)
        #expect(!viewModel.ledgerNeedsGas)
        #expect(viewModel.ledgerClaimEnabled)

        viewModel.claimLedger()
        #expect(client.claimCalls == 1)
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued, Self.ctfKey: .queued])

        client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        client.emit(.sent(noId: Self.ctfNoId, index: 7, txHash: "0xbatch"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.ledgerAnswer = [Self.paid, Self.ctfPaid]
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid, Self.ctfPaid]) }

        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .providerPool, amountRao: 3_241_000_000, status: .claimed, explorerUrl: link),
            SnLedgerClaimRow(id: Self.ctfKey, name: .captureTheFlag, amountRao: 144_076_980, status: .claimed, explorerUrl: link),
        ])
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimFinished)
    }

    // §10: a pool the ledger read could not read is a line of its own in the
    // claim sheet; the claim claims the others, and its report that it could
    // not read that pool (ledger_unavailable, the pool's noId, index 0) is no
    // failure
    @Test func aPoolTheClaimCannotReadIsUnavailableNotAFailure() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        client.unavailablePools = [Self.ctfUnavailable]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()

        #expect(viewModel.ledger == .loaded([Self.account()], unavailablePools: [Self.ctfUnavailable]))
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .providerPool, amountRao: 3_241_000_000, status: .unclaimed, explorerUrl: nil),
            SnLedgerClaimRow(id: SnLedgerAccountKey(noId: Self.ctfNoId, index: 0), name: .captureTheFlag, amountRao: nil, status: .unavailable, explorerUrl: nil),
        ])
        #expect(viewModel.ledgerClaimEnabled)
        #expect(!viewModel.ledgerClaimsBoth)

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued])
        client.emit(.failed(noId: Self.ctfNoId, index: 0, message: "ledger_unavailable: pool 4294967297 is unavailable"))
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        client.ledgerAnswer = [Self.paid]
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid], unavailablePools: [Self.ctfUnavailable]) }

        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, .unavailable])
    }

    // §10: an account the sheet queued whose pool the claim then could not
    // read is unavailable right now, not left pending and not a failure
    @Test func anAccountWhosePoolTheClaimCannotReadIsUnavailable() async {
        let (client, viewModel) = await Self.loaded([Self.account(), Self.ctfAccount()])

        viewModel.claimLedger()
        client.emit(.failed(noId: Self.ctfNoId, index: 0, message: "ledger_unavailable: pool 4294967297 is unavailable"))
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }

        #expect(viewModel.ledgerClaimProgress[Self.ctfKey] == .unavailable)
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, .unavailable])
        // a ledger_unavailable naming no pool is still the failure it was
        viewModel.resetLedgerClaimProgress()
        viewModel.claimLedger()
        client.emit(.failed(noId: 0, index: 0, message: "ledger_unavailable: 503 Service Unavailable"))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }
        #expect(viewModel.ledgerClaimFailures.map(\.failure) == [.unreachable])
    }

    // as Android's and Windows' claim rows: a pool the claim's own read
    // cannot read makes each of its accounts the sheet listed that the claim
    // sent nothing for unavailable right now, whatever its index, the one
    // under the floor too, as the same account at index 0 is; with nothing
    // above the floor left, the sheet shows no figure
    @Test func aPoolTheClaimCannotReadMarksEachUnsentAccountWhateverItsIndex() async {
        let unavailable = "ledger_unavailable: the ledger of Capture the flag (pool 4294967297) could not be read"
        let oneSlot = Self.ctfAccount(claimableRao: 48_025_660)
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), oneSlot]
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.unclaimed, .underFloor])

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued])
        client.emit(.failed(noId: Self.ctfNoId, index: 0, message: unavailable))
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }

        #expect(viewModel.ledgerClaimProgress[Self.ctfKey] == .unavailable)
        #expect(viewModel.ledgerClaimRows.map(\.id) == [Self.key, Self.ctfKey])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, .unavailable])
        #expect(viewModel.ledgerClaimRows.last?.amountRao == nil)
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(!viewModel.ledgerClaimTotalKnown)

        // the same account at index 0 reads the same
        let atZero = Self.account(noId: Self.ctfNoId, index: 0, finalizedRao: 48_025_660, claimableRao: 48_025_660, paidRao: 0, kind: .ctf)
        let zeroKey = SnLedgerAccountKey(noId: Self.ctfNoId, index: 0)
        let zero = FakeLedgerClient()
        zero.chain = Self.configured
        zero.ledgerAnswer = [Self.account(), atZero]
        zero.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let zeroModel = EarningsViewModel(client: zero)
        await zeroModel.refresh()
        zeroModel.claimLedger()
        zero.emit(.failed(noId: Self.ctfNoId, index: 0, message: unavailable))
        zero.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        zero.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        zero.emit(.done)
        await Self.settle { !zeroModel.isLedgerClaiming }
        #expect(zeroModel.ledgerClaimRows.map(\.id) == [Self.key, zeroKey])
        #expect(zeroModel.ledgerClaimRows.map(\.status) == [.claimed, .unavailable])
    }

    // as Android's and Linux's claim rows: a pool's ledger_unavailable marks
    // only its accounts the claim has not sent; one already sent keeps its
    // state
    @Test func aPoolsLedgerUnavailableKeepsASentAccountsState() async {
        let (client, viewModel) = await Self.loaded([Self.account()])

        viewModel.claimLedger()
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        client.emit(.failed(noId: 1, index: 0, message: "ledger_unavailable: the ledger of Pool 1 (pool 1) could not be read"))
        await Self.settle { viewModel.ledgerClaimProgress[SnLedgerAccountKey(noId: 1, index: 0)] == .unavailable }

        #expect(viewModel.ledgerClaimProgress[Self.key] == .sent(txHash: "0xabc"))
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.sent])
        #expect(viewModel.ledgerClaimFailures.isEmpty)
    }

    // as Android's, Linux's and Windows' claim rows: the sheet's read could
    // not read the capture the flag pool, and the claim's own read found its
    // account and claimed it in the batch: that account takes the pool's line,
    // with no figure until vault2 confirms what it paid
    @Test func anAccountTheClaimFindsTakesItsPoolsLine() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        client.unavailablePools = [Self.ctfUnavailable]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        let link = URL(string: "https://evm.taostats.io/tx/0xbatch")

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued])
        client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        client.emit(.sent(noId: Self.ctfNoId, index: 7, txHash: "0xbatch"))
        await Self.settle { viewModel.ledgerClaimProgress[Self.ctfKey] == .sent(txHash: "0xbatch") }
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .providerPool, amountRao: 3_241_000_000, status: .sent, explorerUrl: link),
            SnLedgerClaimRow(id: Self.ctfKey, name: .captureTheFlag, amountRao: nil, status: .sent, explorerUrl: link),
        ])

        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        await Self.settle { viewModel.ledgerClaimProgress[Self.ctfKey] == .confirmed(txHash: "0xbatch", amountRao: 144_076_980) }
        #expect(viewModel.ledgerClaimRows.last == SnLedgerClaimRow(id: Self.ctfKey, name: .captureTheFlag, amountRao: 144_076_980, status: .claimed, explorerUrl: link))

        // read again after Done, the account is the ledger's own row
        client.ledgerAnswer = [Self.paid, Self.ctfPaid]
        client.unavailablePools = []
        client.emit(.done)
        await Self.settle { viewModel.ledger == .loaded([Self.paid, Self.ctfPaid]) }
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .providerPool, amountRao: 3_241_000_000, status: .claimed, explorerUrl: link),
            SnLedgerClaimRow(id: Self.ctfKey, name: .captureTheFlag, amountRao: 144_076_980, status: .claimed, explorerUrl: link),
        ])
    }

    // an account at index 0 has the key its pool's ledger_unavailable names:
    // it is one line either way, unavailable when the claim cannot read its
    // pool, and the found account's line in place of its unreadable pool's
    @Test func anAccountAtIndexZeroIsOneLine() async {
        let ctfAtZero = Self.account(noId: Self.ctfNoId, index: 0, finalizedRao: 144_076_980, claimableRao: 144_076_980, paidRao: 0, kind: .ctf)
        let zeroKey = SnLedgerAccountKey(noId: Self.ctfNoId, index: 0)
        let (client, viewModel) = await Self.loaded([Self.account(), ctfAtZero])

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .queued, zeroKey: .queued])
        client.emit(.failed(noId: Self.ctfNoId, index: 0, message: "ledger_unavailable: the ledger of Capture the flag (pool 4294967297) could not be read"))
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }
        #expect(viewModel.ledgerClaimRows.map(\.id) == [Self.key, zeroKey])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.claimed, .unavailable])
        #expect(viewModel.ledgerClaimFailures.isEmpty)

        // the sheet could not read the pool, and the claim found the account
        let found = FakeLedgerClient()
        found.chain = Self.configured
        found.ledgerAnswer = [Self.account()]
        found.unavailablePools = [Self.ctfUnavailable]
        let foundModel = EarningsViewModel(client: found)
        await foundModel.refresh()
        foundModel.claimLedger()
        found.emit(.sent(noId: Self.ctfNoId, index: 0, txHash: "0xbatch"))
        found.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        await Self.settle { foundModel.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch") }
        #expect(foundModel.ledgerClaimRows.map(\.id) == [Self.key, zeroKey])
        #expect(foundModel.ledgerClaimRows.map(\.status) == [.sent, .sent])
        #expect(foundModel.ledgerClaimRows.map(\.amountRao) == [3_241_000_000, nil])
    }

    // as Android's claim rows: a pool the claim's own read could not read,
    // which the sheet's read did not list at all, gets a line of its own,
    // and names the rows beside it
    @Test func aPoolOnlyTheClaimCouldNotReadGetsALine() async {
        let (client, viewModel) = await Self.loaded([Self.account()])

        viewModel.claimLedger()
        client.emit(.failed(noId: Self.ctfNoId, index: 0, message: "ledger_unavailable: the ledger of Capture the flag (pool 4294967297) could not be read"))
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        await Self.settle { viewModel.ledgerClaimProgress[Self.key] == .sent(txHash: "0xabc") }

        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, name: .providerPool, amountRao: 3_241_000_000, status: .sent, explorerUrl: URL(string: "https://evm.taostats.io/tx/0xabc")),
            SnLedgerClaimRow(id: SnLedgerAccountKey(noId: Self.ctfNoId, index: 0), name: .captureTheFlag, amountRao: nil, status: .unavailable, explorerUrl: nil),
        ])
        #expect(viewModel.ledgerClaimFailures.isEmpty)
        #expect(SnLedgerPoolKind(noId: Self.ctfNoId) == .ctf)
        #expect(SnLedgerPoolKind(noId: 1) == .pool)
    }

    // §10: the relay's claim sheet lists each pool's account, as Android's
    // and Linux's sheets (snClaimRelayRows): Pending, Below the claim minimum
    // under the floor, Claimed with URnetwork's transaction, a pool it could
    // not read; before capture the flag a lone account is listed too
    @Test func theRelaySheetListsEachPoolsAccount() {
        let coldkey = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        let before = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000)]
        )
        #expect(SnClaimRelayRow.rows(before) == [
            SnClaimRelayRow(id: "\(coldkey)/1", name: .pool(noId: 1), coldkeySs58: "", amountRao: 3_241_000_000, status: .pending, txUrl: nil),
        ])
        // nothing to claim and no claim of URnetwork's: no row
        #expect(SnClaimRelayRow.rows(SnClaimStatusInfo(coldkeySs58: coldkey, accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1)])).isEmpty)

        let status = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000 + 48_025_660,
            transferFloorRao: Self.floorRao,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: 48_025_660),
            ]
        )
        #expect(SnClaimRelayRow.rows(status) == [
            SnClaimRelayRow(id: "\(coldkey)/1", name: .providerPool, coldkeySs58: "", amountRao: 3_241_000_000, status: .pending, txUrl: nil),
            SnClaimRelayRow(id: "\(coldkey)/\(Self.ctfNoId)", name: .captureTheFlag, coldkeySs58: "", amountRao: 48_025_660, status: .underFloor, txUrl: nil),
        ])
        // the floor holds for the provider pool's account beside it too
        let smallPool = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            transferFloorRao: Self.floorRao,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 1_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: Self.floorRao),
            ]
        )
        #expect(SnClaimRelayRow.rows(smallPool).map(\.status) == [.underFloor, .pending])

        // URnetwork claimed both in one batch, and a replaced wallet's
        // capture the flag pool could not be read: each row names its coldkey
        let replaced = "5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty"
        let txUrl = "https://evm.taostats.io/tx/0x" + String(repeating: "ab", count: 32)
        let claimed = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            showsClaimed: true,
            claimTxUrl: txUrl,
            claimAmountRao: 3_385_076_980,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimTxHash: "0x" + String(repeating: "ab", count: 32), claimTxUrl: txUrl, claimAmountRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimTxHash: "0x" + String(repeating: "ab", count: 32), claimTxUrl: txUrl, claimAmountRao: 144_076_980),
                SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 1, claimableRao: 1_000_000_000),
                // nothing to claim and no claim of URnetwork's: no row
                SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: Self.ctfNoId, kind: .ctf),
            ],
            unavailablePools: [Self.ctfUnavailable]
        )
        #expect(SnClaimRelayRow.rows(claimed) == [
            SnClaimRelayRow(id: "\(coldkey)/1", name: .providerPool, coldkeySs58: coldkey, amountRao: 3_241_000_000, status: .claimed, txUrl: URL(string: txUrl)),
            SnClaimRelayRow(id: "\(coldkey)/\(Self.ctfNoId)", name: .captureTheFlag, coldkeySs58: coldkey, amountRao: 144_076_980, status: .claimed, txUrl: URL(string: txUrl)),
            SnClaimRelayRow(id: "\(replaced)/1", name: .providerPool, coldkeySs58: replaced, amountRao: 1_000_000_000, status: .pending, txUrl: nil),
            SnClaimRelayRow(id: "\(Self.vault2)/\(Self.ctfNoId)", name: .captureTheFlag, coldkeySs58: "", amountRao: 0, status: .unavailable, txUrl: nil),
        ])

        // a pool the relay could not read lists the rows, capture the flag or not
        let partial = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000)],
            unavailablePools: [SnLedgerUnavailablePool(vault: Self.vault2, noId: 2)]
        )
        #expect(SnClaimRelayRow.rows(partial).map(\.status) == [.pending, .unavailable])
        #expect(SnClaimRelayRow.rows(partial).map(\.name) == [.pool(noId: 1), .pool(noId: 2)])
    }

    // owner, 2026-11-11: a lone account under the floor reads "Below the
    // claim minimum" in the relay's claim sheet too, on its row, before
    // capture the flag as beside it; at the floor it is Pending
    @Test func theRelaySheetListsALoneAccountUnderTheFloor() {
        let coldkey = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        let lone = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 1_000_000,
            transferFloorRao: Self.floorRao,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 1_000_000)]
        )
        #expect(SnClaimRelayRow.rows(lone) == [
            SnClaimRelayRow(id: "\(coldkey)/1", name: .pool(noId: 1), coldkeySs58: "", amountRao: 1_000_000, status: .underFloor, txUrl: nil),
        ])
        let atFloor = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: Self.floorRao,
            transferFloorRao: Self.floorRao,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: Self.floorRao)]
        )
        #expect(SnClaimRelayRow.rows(atFloor).map(\.status) == [.pending])
        // a replaced wallet's account under it lists each coldkey's
        let replaced = "5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty"
        let twoColdkeys = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            transferFloorRao: Self.floorRao,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 1, claimableRao: 1_000_000),
            ]
        )
        #expect(SnClaimRelayRow.rows(twoColdkeys).map(\.status) == [.pending, .underFloor])
        #expect(SnClaimRelayRow.rows(twoColdkeys).map(\.coldkeySs58) == [coldkey, replaced])
    }

    // §10: a network with no wallet on this device sees the relay's total,
    // and under it, beside capture the flag, the primary coldkey's pools it
    // adds up and each pool the relay could not read, which it leaves out;
    // with no account read there is no total, never 0; one operator pool's
    // total says it all, as before
    @Test func theRelayTileListsThePoolsItAddsUp() async {
        let coldkey = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        let replaced = "5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty"
        let unavailableRow = SnClaimRelayRow(id: "\(Self.vault2)/\(Self.ctfNoId)", name: .captureTheFlag, coldkeySs58: "", amountRao: 0, status: .unavailable, txUrl: nil)
        let client = FakeLedgerClient()
        client.wallet = nil
        client.chain = Self.configured
        client.relayAnswer = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            showsTile: true,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000)],
            unavailablePools: [Self.ctfUnavailable]
        )
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()

        #expect(viewModel.ledgerTileWithRelay == SnLedgerTilePresentation(
            balances: .claimable(3_241_000_000, rows: [
                SnClaimRelayRow(id: "\(coldkey)/1", name: .providerPool, coldkeySs58: "", amountRao: 3_241_000_000, status: .pending, txUrl: nil),
                unavailableRow,
            ]),
            showsClaim: false,
            claimEnabled: false,
            showsPools: false
        ))

        // both pools read: each one the total adds up, the primary coldkey's
        // only, and the capture the flag one under the floor
        client.relayAnswer = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000 + 48_025_660,
            transferFloorRao: Self.floorRao,
            showsTile: true,
            accounts: [
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
                SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: 48_025_660),
                SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 1, claimableRao: 1_000_000_000),
            ]
        )
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTileWithRelay?.balances == .claimable(3_241_000_000 + 48_025_660, rows: [
            SnClaimRelayRow(id: "\(coldkey)/1", name: .providerPool, coldkeySs58: "", amountRao: 3_241_000_000, status: .pending, txUrl: nil),
            SnClaimRelayRow(id: "\(coldkey)/\(Self.ctfNoId)", name: .captureTheFlag, coldkeySs58: "", amountRao: 48_025_660, status: .underFloor, txUrl: nil),
        ]))

        // nothing read: no total, and the pool it could not read
        client.relayAnswer = SnClaimStatusInfo(coldkeySs58: coldkey, showsTile: true, unavailablePools: [Self.ctfUnavailable])
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTileWithRelay?.balances == .claimable(nil, rows: [unavailableRow]))
        // only a replaced wallet's account read: still none of the primary
        // coldkey's, so no total either, never 0 (Android's
        // snClaimRelayTotalKnown); the claim sheet the same
        let onlyReplaced = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            showsTile: true,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 1, claimableRao: 1_000_000_000)],
            unavailablePools: [Self.ctfUnavailable]
        )
        #expect(onlyReplaced.knownClaimableRao == nil)
        client.relayAnswer = onlyReplaced
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTileWithRelay?.balances == .claimable(nil, rows: [unavailableRow]))
        // a whole answer always has its total
        #expect(SnClaimStatusInfo(coldkeySs58: coldkey, claimableRao: 0).knownClaimableRao == 0)

        // a whole answer with one operator pool: the total alone, as before
        client.relayAnswer = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            transferFloorRao: Self.floorRao,
            showsTile: true,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000)]
        )
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTileWithRelay?.balances == .claimable(3_241_000_000))

        // a total that is one account's under the floor says "Below the claim
        // minimum" under it (owner, 2026-11-11; Linux's no-wallet tile)
        let loneUnderFloor = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 1_000_000,
            transferFloorRao: Self.floorRao,
            showsTile: true,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 1_000_000)]
        )
        client.relayAnswer = loneUnderFloor
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTileWithRelay?.balances == .claimable(1_000_000, rows: [], underFloor: true))
        // a replaced wallet's account is not in the total, and so not in its
        // floor either
        var withReplaced = loneUnderFloor
        withReplaced.accounts.append(SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 1, claimableRao: 1_000_000_000))
        #expect(SnClaimRelayRow.tileTotalUnderFloor(withReplaced))
        // where the tile lists rows, each says it for itself, not the total
        var besideCtf = loneUnderFloor
        besideCtf.accounts.append(SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimableRao: 144_076_980))
        #expect(!SnClaimRelayRow.tileTotalUnderFloor(besideCtf))
        #expect(SnClaimRelayRow.tileRows(besideCtf).map(\.status) == [.underFloor, .pending])
    }

    // §10: the relay's per-pool rows read through the SDK: each account's
    // kind and URnetwork's claim, the pools it could not read, and the floor
    @Test func theSdkClaimStatusMapsEachPoolsAccount() throws {
        let coldkey = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        let pool = SdkSnClaimRelayAccount()
        pool.coldkeySs58 = coldkey
        pool.noId = 1
        pool.kind = SdkSnLedgerPoolKindPool
        pool.claimableRao = 3_241_000_000
        let ctf = SdkSnClaimRelayAccount()
        ctf.coldkeySs58 = coldkey
        ctf.noId = Self.ctfNoId
        ctf.kind = SdkSnLedgerPoolKindCtf
        ctf.claimTxHash = "0xabc"
        ctf.claimTxUrl = "https://evm.taostats.io/tx/0xabc"
        ctf.claimAmountRao = 144_076_980
        let accounts = try #require(SdkSnClaimRelayAccountList())
        accounts.add(pool)
        accounts.add(ctf)
        let unavailable = SdkSnLedgerUnavailablePool()
        unavailable.vault = Self.vault2
        unavailable.noId = 2
        unavailable.kind = SdkSnLedgerPoolKindPool
        let pools = try #require(SdkSnLedgerUnavailablePoolList())
        pools.add(unavailable)
        let result = SdkSnClaimStatusResult()
        result.coldkeySs58 = coldkey
        result.claimableRao = 3_241_000_000
        result.transferFloorRao = Self.floorRao
        result.accounts = accounts
        result.unavailablePools = pools
        result.partial = true

        let status = EarningsSdkClient.claimStatus(from: result)
        #expect(status.accounts == [
            SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000),
            SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: Self.ctfNoId, kind: .ctf, claimTxHash: "0xabc", claimTxUrl: "https://evm.taostats.io/tx/0xabc", claimAmountRao: 144_076_980),
        ])
        #expect(status.unavailablePools == [SnLedgerUnavailablePool(vault: Self.vault2, noId: 2)])
        #expect(status.transferFloorRao == Self.floorRao)
        #expect(status.claimableRao == 3_241_000_000)
    }

    // owner, 2026-11-11: the "you won a slot" line shows for every unclaimed
    // win, the sdk's UnclaimedWins (sdk-ctf-v2 §1), one each, newest first,
    // providers before extenders within an epoch; a claimed win is no line,
    // and neither is the latest win alone; a role this build does not know
    // draws none; an answer that could not be read is a read that failed
    // (nil), which keeps the lines (every app, 2026-11-12)
    @Test func theSdkWinReadGivesEveryUnclaimedWinNewestFirst() throws {
        func win(_ role: String, _ country: String, _ epoch: Int64) -> SdkSnCtfWin {
            let win = SdkSnCtfWin()
            win.role = role
            win.country = country
            win.epoch = epoch
            return win
        }
        // claimed: in Wins, the latest, and not in UnclaimedWins
        let claimedWin = win(SdkSnCtfRoleProvider, "de", 12)
        let all = try #require(SdkSnCtfWinList())
        all.add(claimedWin)
        let unclaimed = try #require(SdkSnCtfWinList())
        unclaimed.add(win(SdkSnCtfRoleProvider, "is", 10))
        unclaimed.add(win(SdkSnCtfRoleExtender, "la", 10))
        unclaimed.add(win("observer", "is", 10))
        unclaimed.add(win(SdkSnCtfRoleProvider, "", 10))
        unclaimed.add(win(SdkSnCtfRoleProvider, "is", 9))
        // out of order: the line still goes first
        unclaimed.add(win(SdkSnCtfRoleExtender, "fj", 11))
        for i in 0..<unclaimed.len() {
            all.add(unclaimed.get(i))
        }
        let result = SdkSnCtfClientResult()
        result.wins = all
        result.latestWin = claimedWin
        result.unclaimedWins = unclaimed
        let expected = [
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "fj", epoch: 11)),
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10)),
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la", epoch: 10)),
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 9)),
        ]
        // the network's answer: no client named
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: result) == SnCtfWinsAnswer(wins: expected))
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: result)?.fromClient == false)
        // a client's answer alone: the sdk's read with the client token, or an
        // older server's
        result.clientId = Self.clientId
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: result) == SnCtfWinsAnswer(wins: expected, clientId: Self.clientId))
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: result)?.fromClient == true)
        result.clientId = ""

        // every win claimed: a read that answered with no line
        let allClaimed = SdkSnCtfClientResult()
        allClaimed.wins = all
        allClaimed.latestWin = claimedWin
        allClaimed.unclaimedWins = SdkSnCtfWinList()
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: allClaimed) == SnCtfWinsAnswer(wins: []))
        // an answer without the list the sdk always sends, or with an error:
        // a read that failed, which keeps the lines
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: SdkSnCtfClientResult()) == nil)
        result.error = Self.snError(code: SdkSnErrorCodeCtfUnavailable, message: "503 Service Unavailable")
        #expect(EarningsSdkClient.ctfUnclaimedWins(from: result) == nil)

        #expect(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is")?.role == .provider)
        #expect(SnCtfWinInfo(role: "observer", country: "is") == nil)
        #expect(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "") == nil)
    }

    // the lines are newest first by epoch, in the sdk's order within one
    @Test func theWinsAreNewestFirst() throws {
        let p9 = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 9))
        let e10 = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "is", epoch: 10))
        let p10 = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let p11 = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "fj", epoch: 11))
        #expect(SnCtfWinInfo.newestFirst([p9, p10, e10, p11]) == [p11, p10, e10, p9])
        #expect(SnCtfWinInfo.newestFirst([e10, p10]) == [e10, p10])
        #expect(SnCtfWinInfo.newestFirst([]).isEmpty)
    }

    // the refresh reads every unclaimed win beside the ledger, and a later
    // read without one draws no line
    @Test func theRefreshReadsEveryUnclaimedWin() async throws {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        let wins = [
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10)),
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "is", epoch: 10)),
            try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 9)),
        ]
        client.ctfWinsAnswer = wins
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == wins }
        #expect(viewModel.ctfWins == wins)

        client.ctfWinsAnswer = []
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins.isEmpty }
        #expect(viewModel.ctfWins.isEmpty)
    }

    // the wins' read never holds up the refresh, which the sdk can wait on
    // for up to a minute; the lines follow once it lands
    @Test func theWinsReadNeverHoldsUpTheRefresh() async throws {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la", epoch: 9))
        client.ctfWinsAnswer = [win]
        var open: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { open = $0 }
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.loadedOnce)
        #expect(!viewModel.isLoading)
        #expect(viewModel.ledger == .loaded([Self.account(), Self.ctfAccount()]))
        #expect(viewModel.ctfWins.isEmpty)

        open?.yield()
        await Self.settle { viewModel.ctfWins == [win] }
        #expect(viewModel.ctfWins == [win])
    }

    // a claim reads the wins again at its Done, so a win whose award it paid
    // loses its line; one that paid an account reads them on the schedule
    // after it too, and one that paid nothing reads once, at Done, as on
    // Android and Linux
    @Test func aClaimThatPaysReadsTheWinsAgain() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [win]
        let clock = FakeClock()
        let viewModel = EarningsViewModel(client: client, sleep: { await clock.sleep($0) })
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [win] }
        #expect(client.ctfWinsReads == 1)

        viewModel.claimLedger()
        client.emit(.sent(noId: Self.ctfNoId, index: 7, txHash: "0xbatch"))
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.ctfWinsAnswer = []
        client.emit(.done)
        await Self.settle { viewModel.ctfWins.isEmpty }
        #expect(viewModel.ctfWins.isEmpty)
        #expect(client.ctfWinsReads == 2)
        await Self.settle { clock.sleeping == 1 }
        #expect(clock.waits == [.seconds(30)])

        // paid nothing: one read at its Done, and no wait of its own beside
        // the paying claim's
        viewModel.resetLedgerClaimProgress()
        viewModel.claimLedger()
        client.emit(.failed(noId: 0, index: 0, message: "chain_rpc_unreachable: dial tcp: i/o timeout"))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming && client.ctfWinsReads == 3 }
        await Self.settle { false }
        #expect(client.ctfWinsReads == 3)
        #expect(clock.waits == [.seconds(30)])
        #expect(clock.sleeping == 1)
    }

    // every app's schedule: the SDK's Done comes once the claim is in a
    // block, and the server says a win is claimed only once vault2's claimed
    // at the finalized head covers the claim, so a claim that paid an account
    // reads the wins at Done and again 30 s, 60 s and 120 s after it. The
    // server here still lists the paid win at Done and 30 s after it (with
    // another win by then): its line stays until a read says it is claimed,
    // the other's stays, and nothing is read after 120 s
    @Test func aClaimThatPaysReadsTheWinsUntilTheServerSaysClaimed() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let other = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la", epoch: 11))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [win]
        let clock = FakeClock()
        let viewModel = EarningsViewModel(client: client, sleep: { await clock.sleep($0) })
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 1 && viewModel.ctfWins == [win] }

        viewModel.claimLedger()
        client.emit(.sent(noId: Self.ctfNoId, index: 7, txHash: "0xbatch"))
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.ctfWinsAnswers = [[win], [other, win]]
        client.ctfWinsAnswer = [other]
        client.emit(.done)
        // at Done: still unclaimed, and nothing more until 30 s after it
        await Self.settle { client.ctfWinsReads == 2 && clock.sleeping == 1 }
        await Self.settle { false }
        #expect(client.ctfWinsReads == 2)
        #expect(viewModel.ctfWins == [win])
        #expect(clock.waits == [.seconds(30)])

        // 30 s after Done: still unclaimed
        clock.advance()
        await Self.settle { client.ctfWinsReads == 3 && viewModel.ctfWins == [other, win] }
        #expect(viewModel.ctfWins == [other, win])

        // 60 s after Done: claimed, and its line goes
        clock.advance()
        await Self.settle { client.ctfWinsReads == 4 && viewModel.ctfWins == [other] }
        #expect(viewModel.ctfWins == [other])

        // 120 s after Done: the last read
        clock.advance()
        await Self.settle { client.ctfWinsReads == 5 }
        await Self.settle { false }
        #expect(client.ctfWinsReads == 5)
        #expect(viewModel.ctfWins == [other])
        #expect(clock.sleeping == 0)
        #expect(clock.waits == [.seconds(30), .seconds(30), .seconds(60)])
        #expect(EarningsViewModel.ctfWinsReadsAfterClaim == [.seconds(30), .seconds(60), .seconds(120)])
    }

    // the next paying claim's Done starts the reads after a claim over, and
    // one that paid nothing leaves them be; they end with the session, which
    // a sign-out ends (here the view model's own, which goes with it)
    @Test func theWinsReadsAfterAClaimStartOverAndEndWithTheSession() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [win]
        let clock = FakeClock()
        weak var released: EarningsViewModel?
        do {
            let viewModel = EarningsViewModel(client: client, sleep: { await clock.sleep($0) })
            released = viewModel
            await viewModel.refresh()
            await Self.settle { client.ctfWinsReads == 1 }

            // paid: the read at Done, then a wait
            viewModel.claimLedger()
            client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_241_000_000))
            client.emit(.done)
            await Self.settle { client.ctfWinsReads == 2 && clock.sleeping == 1 }

            // paid nothing (needs_gas): one read at its Done, and the reads
            // after the paying claim go on
            viewModel.resetLedgerClaimProgress()
            viewModel.claimLedger()
            client.emit(.failed(noId: Self.ctfNoId, index: 7, message: "needs_gas: the gas key cannot pay for the claim"))
            client.emit(.done)
            await Self.settle { !viewModel.isLedgerClaiming && client.ctfWinsReads == 3 }
            #expect(clock.waits == [.seconds(30)])
            clock.advance()
            await Self.settle { client.ctfWinsReads == 4 && clock.sleeping == 1 }
            #expect(clock.waits == [.seconds(30), .seconds(30)])

            // paid (already_claimed): read at its Done, and its own reads from
            // there; the wait it cut short reads nothing
            viewModel.resetLedgerClaimProgress()
            viewModel.claimLedger()
            client.emit(.failed(noId: 1, index: 42, message: "already_claimed: another sender claimed it"))
            client.emit(.done)
            await Self.settle { client.ctfWinsReads == 5 && clock.sleeping == 2 }
            #expect(clock.waits == [.seconds(30), .seconds(30), .seconds(30)])
            clock.advance()
            await Self.settle { client.ctfWinsReads == 6 && clock.sleeping == 1 }
            await Self.settle { false }
            #expect(client.ctfWinsReads == 6)
            #expect(clock.waits == [.seconds(30), .seconds(30), .seconds(30), .seconds(30)])
        }

        // the view model is gone, as at a sign-out: nothing is read after it
        await Self.settle { released == nil }
        #expect(released == nil)
        clock.advance()
        await Self.settle { false }
        #expect(client.ctfWinsReads == 6)
        #expect(clock.sleeping == 0)
    }

    // every app, 2026-11-12: a read of the wins that failed keeps the last
    // good read's lines and never blanks them; a good read that no longer
    // lists a win takes its line away; and the first read with a new view
    // model (a sign-in) shows none until it answers
    @Test func aFailedWinsReadKeepsTheLastGoodLines() async throws {
        let iceland = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let laos = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la", epoch: 9))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [iceland, laos]
        let clock = FakeClock()
        let viewModel = EarningsViewModel(client: client, sleep: { await clock.sleep($0) })
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [iceland, laos] }
        #expect(viewModel.ctfWins == [iceland, laos])

        // a failure between two good reads leaves the lines as they were
        client.ctfWinsAnswer = nil
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 2 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [iceland, laos])
        client.ctfWinsAnswer = [laos]
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 3 && viewModel.ctfWins == [laos] }
        #expect(viewModel.ctfWins == [laos])

        // the reads after a paying claim: a failure among them keeps the line
        // until a good read says the win is claimed
        viewModel.claimLedger()
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.ctfWinsAnswers = [nil, nil]
        client.ctfWinsAnswer = []
        client.emit(.done)
        await Self.settle { client.ctfWinsReads == 4 && clock.sleeping == 1 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [laos])
        clock.advance()
        await Self.settle { client.ctfWinsReads == 5 && clock.sleeping == 1 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [laos])
        clock.advance()
        await Self.settle { client.ctfWinsReads == 6 && viewModel.ctfWins.isEmpty }
        #expect(viewModel.ctfWins.isEmpty)

        // the next account's screens: none until a read answers, a failed one
        // included
        let next = FakeLedgerClient()
        next.chain = Self.configured
        next.ctfWinsAnswer = nil
        let nextModel = EarningsViewModel(client: next, sleep: { await clock.sleep($0) })
        await nextModel.refresh()
        await Self.settle { next.ctfWinsReads == 1 }
        await Self.settle { false }
        #expect(nextModel.ctfWins.isEmpty)
    }

    // a read asked for while one is out (a claim's Done during the refresh's
    // read, whose route is slow) starts at once, as every read keeps its time,
    // and the lines show the newest read's good answer: an older read's late
    // answer never puts back a line a newer one took away, and a newer read
    // that fails drops no older good answer still to land
    @Test func aWinsReadStartsAtOnceAndTheNewestGoodAnswerShows() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [win]
        let clock = FakeClock()
        let viewModel = EarningsViewModel(client: client, sleep: { await clock.sleep($0) })
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [win] }

        // the refresh's read is slow: the server said unclaimed as it started
        var openSlow: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { openSlow = $0 }
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 2 }

        // the claim's Done reads at once beside it, and says claimed
        client.ctfWinsAnswer = []
        viewModel.claimLedger()
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.emit(.done)
        await Self.settle { client.ctfWinsReads == 3 && viewModel.ctfWins.isEmpty }
        #expect(viewModel.ctfWins.isEmpty)

        // the slow read's late answer is older: it puts no line back
        openSlow?.yield()
        await Self.settle { false }
        #expect(viewModel.ctfWins.isEmpty)

        // a slow good read, then a newer one that fails: the good answer shows
        // when it lands
        client.ctfWinsAnswer = [win]
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [win] }
        var openGood: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { openGood = $0 }
        client.ctfWinsAnswer = []
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 5 }
        client.ctfWinsAnswer = nil
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 6 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [win])
        openGood?.yield()
        await Self.settle { viewModel.ctfWins.isEmpty }
        #expect(viewModel.ctfWins.isEmpty)
    }

    // MARK: the last round's shared decisions (owner, 2026-11-12)

    // a network answer beats a client answer: once a network answer has shown
    // since the sign-in, a client answer (the sdk's read with the client token
    // after the network credential's failed) is a read that failed for its
    // lines, whatever it holds; the next network answer replaces them as before
    @Test func aClientAnswerAfterANetworkAnswerLeavesTheNetworkLines() async throws {
        let iceland = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let laos = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la", epoch: 9))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [iceland, laos]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [iceland, laos] }
        #expect(viewModel.ctfWins == [iceland, laos])

        // this client's win alone: the other client's line stays
        client.ctfWinsClientId = Self.clientId
        client.ctfWinsAnswer = [iceland]
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 2 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [iceland, laos])
        // and a client answer with no win takes none away
        client.ctfWinsAnswer = []
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 3 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [iceland, laos])

        // the next network answer: a win claimed
        client.ctfWinsClientId = ""
        client.ctfWinsAnswer = [laos]
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [laos] }
        #expect(viewModel.ctfWins == [laos])
    }

    // a client answer alone, as from a server before the network answer,
    // whose every answer is a client's, shows its lines as any good read's
    // do; and a network answer, once there is one, replaces them, even one
    // from a read that started first
    @Test func aClientAnswerAloneShowsItsLines() async throws {
        let iceland = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let laos = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la", epoch: 9))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsClientId = Self.clientId
        client.ctfWinsAnswer = [iceland, laos]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [iceland, laos] }
        #expect(viewModel.ctfWins == [iceland, laos])

        // a read that failed keeps them, and the next client answer replaces them
        client.ctfWinsAnswer = nil
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 2 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [iceland, laos])
        client.ctfWinsAnswer = [laos]
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWins == [laos] }
        #expect(viewModel.ctfWins == [laos])

        // among client answers, the newest read's shows: an older read's late
        // answer never puts back a line a newer one took away
        var openOld: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { openOld = $0 }
        client.ctfWinsAnswers = [[iceland, laos], []]
        await viewModel.refresh()
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 5 && viewModel.ctfWins.isEmpty }
        #expect(viewModel.ctfWins.isEmpty)
        openOld?.yield()
        await Self.settle { false }
        #expect(viewModel.ctfWins.isEmpty)

        // a network read that is slow, and the next read whose network read
        // failed and whose client token answered: the client answer shows
        // first, then the network answer beats it
        var openSlow: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { openSlow = $0 }
        client.ctfWinsClientIds = ["", Self.clientId]
        client.ctfWinsAnswers = [[iceland, laos], [iceland]]
        await viewModel.refresh()
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 7 && viewModel.ctfWins == [iceland] }
        #expect(viewModel.ctfWins == [iceland])
        openSlow?.yield()
        await Self.settle { viewModel.ctfWins == [iceland, laos] }
        #expect(viewModel.ctfWins == [iceland, laos])
        // and no client answer replaces its lines since
        client.ctfWinsAnswer = []
        await viewModel.refresh()
        await Self.settle { client.ctfWinsReads == 8 }
        await Self.settle { false }
        #expect(viewModel.ctfWins == [iceland, laos])
    }

    // macOS: leaving Account drops its view model, and the claim in flight is
    // the session's, so it goes on: the view model built on coming back shows
    // it as it went on, with Claim held and the tile's Claim opening it, no
    // second claim starts, the figure is what the claim moves whatever the
    // read since says, and its Done lands there
    @Test func aClaimInFlightOutlivesTheViewModel() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [win]
        let clock = FakeClock()
        let session = EarningsSession(client: client, sleep: { await clock.sleep($0) })
        weak var released: EarningsViewModel?
        do {
            let first = EarningsViewModel(session: session)
            released = first
            await first.refresh()
            await Self.settle { first.ctfWins == [win] }
            first.claimLedger()
            #expect(first.isLedgerClaiming)
            #expect(client.claimCalls == 1)
            client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
            await Self.settle { first.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch") }
        }
        // Account left: its view model is gone
        await Self.settle { released == nil }
        #expect(released == nil)

        // the claim goes on meanwhile
        client.emit(.sent(noId: Self.ctfNoId, index: 7, txHash: "0xbatch"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        await Self.settle { session.ledgerClaimProgress[Self.key] == .confirmed(txHash: "0xbatch", amountRao: 3_241_000_000) }

        // Account again: the session's lines at once, and the claim as it went
        // on, over a read that says the confirmed account is paid
        let second = EarningsViewModel(session: session)
        #expect(second.ctfWins == [win])
        client.ledgerAnswer = [Self.paid, Self.ctfAccount()]
        await second.refresh()
        #expect(second.isLedgerClaiming)
        #expect(second.ledgerClaimProgress == [
            Self.key: .confirmed(txHash: "0xbatch", amountRao: 3_241_000_000),
            Self.ctfKey: .sent(txHash: "0xbatch"),
        ])
        #expect(second.ledgerClaimRows.map(\.status) == [.claimed, .sent])
        // the tile's Claim opens it (it starts the sheet over, but for a claim
        // in flight), and the sheet's Claim waits for it
        #expect(second.ledgerTile?.claimEnabled == true)
        second.resetLedgerClaimProgress()
        #expect(second.ledgerClaimProgress.count == 2)
        #expect(!second.ledgerClaimEnabled)
        second.claimLedger()
        #expect(client.claimCalls == 1)
        // what the claim moves, whatever the read since says
        #expect(second.ledgerClaimFigureRao == 3_241_000_000 + 144_076_980)
        #expect(second.ledgerClaimTotalKnown)
        #expect(second.ledgerClaimsBoth)
        #expect(!second.ledgerClaimUnavailable)

        // its Done lands with this view model: the wins at Done and on the
        // schedule, and the subnet again
        let ledgerReads = client.ledgerReads
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.ctfWinsAnswer = []
        client.ledgerAnswer = [Self.paid, Self.ctfPaid]
        client.emit(.done)
        await Self.settle { !second.isLedgerClaiming && second.ctfWins.isEmpty && second.ledger == .loaded([Self.paid, Self.ctfPaid]) }
        #expect(!second.isLedgerClaiming)
        #expect(second.ledgerClaimFinished)
        #expect(second.ctfWins.isEmpty)
        #expect(client.ledgerReads == ledgerReads + 1)
        #expect(second.ledger == .loaded([Self.paid, Self.ctfPaid]))
        await Self.settle { clock.sleeping == 1 }
        #expect(clock.waits == [.seconds(30)])
        // the claim over, Claim follows the read again
        #expect(second.ledgerTile?.claimEnabled == false)
    }

    // a claim's Done while no Account screen is up lands in the session: the
    // wins are read at it and on the schedule after it with no view model,
    // and the next one shows the claim's end and the lines; a sign-out, which
    // ends the session, ends the reads
    @Test func aClaimsDoneWithNoScreenUpLandsInTheSession() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.ctfWinsAnswer = [win]
        let clock = FakeClock()
        weak var releasedSession: EarningsSession?
        do {
            let session = EarningsSession(client: client, sleep: { await clock.sleep($0) })
            releasedSession = session
            do {
                let first = EarningsViewModel(session: session)
                await first.refresh()
                await Self.settle { first.ctfWins == [win] }
                first.claimLedger()
            }
            #expect(session.isLedgerClaiming)

            // Done with no view model: the server still says unclaimed at it
            client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
            client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
            client.emit(.done)
            await Self.settle { !session.isLedgerClaiming && client.ctfWinsReads == 2 && clock.sleeping == 1 }
            #expect(!session.isLedgerClaiming)
            #expect(session.ctfWins == [win])
            // 30 s after it, still with no view model: claimed
            client.ctfWinsAnswer = []
            clock.advance()
            await Self.settle { client.ctfWinsReads == 3 && session.ctfWins.isEmpty }
            #expect(session.ctfWins.isEmpty)

            // Account again: the claim's end, and the lines as last read
            let second = EarningsViewModel(session: session)
            #expect(second.ledgerClaimFinished)
            #expect(second.ctfWins.isEmpty)
            #expect(second.ledgerClaimProgress[Self.key] == .confirmed(txHash: "0xbatch", amountRao: 3_241_000_000))
            // the tile's Claim starts a sheet over, the claim being over
            second.resetLedgerClaimProgress()
            #expect(second.ledgerClaimProgress.isEmpty)
        }
        // a sign-out ends the session, and the reads after the claim with it
        await Self.settle { releasedSession == nil }
        #expect(releasedSession == nil)
        clock.advance()
        await Self.settle { false }
        #expect(client.ctfWinsReads == 3)
    }

    // the screens draw the view model, so a change of the session's claim or
    // lines is a change of the view model's
    @Test func theViewModelChangesWithTheSession() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let (client, viewModel) = await Self.loaded([Self.account()])
        var changes = 0
        let watch = viewModel.objectWillChange.sink { _ in changes += 1 }
        defer { watch.cancel() }

        // the claim starts: the session's change alone
        viewModel.claimLedger()
        #expect(changes > 0)
        // its event
        let started = changes
        client.emit(.sent(noId: 1, index: 42, txHash: "0xabc"))
        await Self.settle { changes > started }
        #expect(changes > started)
        // a wins read's answer
        let sent = changes
        client.ctfWinsAnswer = [win]
        viewModel.session.readCtfWins()
        await Self.settle { viewModel.ctfWins == [win] }
        #expect(changes > sent)
    }

    // iOS: the claim sheet swiped away during a claim, and opened again from
    // the tile's Claim or the relay's "Claim it yourself": the claim as it
    // went on, never a sheet started over, and Claim held until Done
    @Test func aSheetOpenedAgainDuringAClaimShowsIt() async {
        let (client, viewModel) = await Self.loaded([Self.account(), Self.ctfAccount()])
        viewModel.claimLedger()
        client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        await Self.settle { viewModel.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch") }

        #expect(viewModel.ledgerTile?.claimEnabled == true)
        viewModel.resetLedgerClaimProgress()
        #expect(viewModel.ledgerClaimProgress == [Self.key: .sent(txHash: "0xbatch"), Self.ctfKey: .queued])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.sent, .pending])
        #expect(!viewModel.ledgerClaimEnabled)
        viewModel.claimLedger()
        #expect(client.claimCalls == 1)

        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.done)
        await Self.settle { viewModel.ledgerClaimFinished }
        // the claim over, the sheet starts over when opened again
        viewModel.resetLedgerClaimProgress()
        #expect(viewModel.ledgerClaimProgress.isEmpty)
    }

    // the v1 claim is the session's too: macOS leaves Account during it, and
    // the view model built on coming back shows it as it went on, starts no
    // second one, and gets its Done
    @Test func aV1ClaimInFlightOutlivesTheViewModel() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.v1Claims = [
            SnEpochClaimInfo(epoch: 7, shareBps: 100, amountRao: 1_000_000_000, status: .claimable, claimOpenBlock: 0, expiryBlock: 0, txHash: ""),
        ]
        let session = EarningsSession(client: client)
        do {
            let first = EarningsViewModel(session: session)
            await first.refresh()
            first.claimAll()
            #expect(first.isClaiming)
            #expect(client.v1ClaimCalls == 1)
        }
        client.emitV1(.sent(epoch: 7, txHash: "0xv1"))
        await Self.settle { session.claimProgress[7] == .sent(txHash: "0xv1") }

        let second = EarningsViewModel(session: session)
        await second.refresh()
        #expect(second.isClaiming)
        #expect(second.claimProgress == [7: .sent(txHash: "0xv1")])
        // the tile's Claim starts the sheet over, but for a claim in flight
        second.resetClaimProgress()
        #expect(second.claimProgress == [7: .sent(txHash: "0xv1")])
        second.claimAll()
        #expect(client.v1ClaimCalls == 1)

        let ledgerReads = client.ledgerReads
        client.emitV1(.confirmed(epoch: 7, txHash: "0xv1", amountRao: 1_000_000_000))
        client.emitV1(.done)
        await Self.settle { second.claimFinished && client.ledgerReads == ledgerReads + 1 }
        #expect(second.claimFinished)
        #expect(second.claimProgress == [7: .confirmed(txHash: "0xv1", amountRao: 1_000_000_000)])
        #expect(client.ledgerReads == ledgerReads + 1)
    }

    // the figure during a claim is what the claim moves: the accounts it sends
    // whose amount is known and above the floor, as Claim found them; never
    // 0, never an account under the floor or of an amount not known, and no
    // read and no event during the claim changes it
    @Test func theFigureDuringAClaimIsWhatTheClaimMoves() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        // capture the flag's under the floor, and a pool that could not be read
        let small = Self.ctfAccount(claimableRao: 50_000_000)
        client.ledgerAnswer = [Self.account(), Self.account(noId: 2, index: 3, claimableRao: 1_000_000_000), small]
        client.unavailablePools = [SnLedgerUnavailablePool(vault: Self.vault2, noId: 3, kind: .pool)]
        client.relayAnswer = SnClaimStatusInfo(transferFloorRao: Self.floorRao)
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.ledgerClaimFigureRao == 4_241_000_000)
        #expect(viewModel.ledgerClaimTotalKnown)

        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimFigureRao == 4_241_000_000)
        #expect(viewModel.ledgerClaimTotalKnown)
        #expect(!viewModel.ledgerClaimsBoth)
        // the sdk tries the account under the floor too, and claims one the
        // sheet did not list: neither is in the figure
        client.emit(.sent(noId: Self.ctfNoId, index: 7, txHash: "0xbatch"))
        client.emit(.sent(noId: 3, index: 1, txHash: "0xbatch"))
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.confirmed(noId: 2, index: 3, txHash: "0xbatch", amountRao: 1_000_000_000))
        await Self.settle { viewModel.ledgerClaimProgress.count == 4 }
        #expect(viewModel.ledgerClaimFigureRao == 4_241_000_000)
        // a read during the claim says both are paid: still the claim's figure,
        // never 0, nor "unavailable"
        client.ledgerAnswer = [Self.paid, Self.account(noId: 2, index: 3, claimableRao: 0, paidRao: 1_000_000_000), small]
        await viewModel.refreshSubnet()
        #expect(viewModel.ledgerClaimableRao == 0)
        #expect(viewModel.ledgerClaimFigureRao == 4_241_000_000)
        #expect(viewModel.ledgerClaimTotalKnown)
        client.ledgerAnswer = nil
        await viewModel.refreshSubnet()
        #expect(!viewModel.ledgerClaimUnavailable)
        #expect(viewModel.ledgerClaimFigureRao == 4_241_000_000)

        // after Done, what a claim pays, from the read
        client.ledgerAnswer = [Self.paid, Self.account(noId: 2, index: 3, claimableRao: 0, paidRao: 1_000_000_000), small]
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming && viewModel.ledger.accounts.count == 3 }
        #expect(viewModel.ledgerClaimFigureRao == viewModel.ledgerClaimableRao)
        #expect(viewModel.ledgerClaimFigureRao == 0)
    }

    // the figure is fixed at the press until Done (every app, 2026-11-12): an
    // account the sdk then sends nothing for says so on its own line,
    // claimable with the gas card's top-up, and the figure and Claim both
    // stay what Claim named
    @Test func anAccountShortOfGasLeavesTheFigureAsClaimNamedIt() async {
        let (client, viewModel) = await Self.loaded([Self.account(), Self.ctfAccount()])
        viewModel.claimLedger()
        #expect(viewModel.ledgerClaimsBoth)
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xone", amountRao: 3_241_000_000))
        client.emit(.failed(noId: Self.ctfNoId, index: 7, message: "needs_gas: the gas key cannot pay for the claim"))
        await Self.settle { viewModel.ledgerClaimProgress[Self.ctfKey] == .needsGas }
        #expect(viewModel.ledgerClaimFigureRao == 3_241_000_000 + 144_076_980)
        #expect(viewModel.ledgerClaimTotalKnown)
        #expect(viewModel.ledgerClaimsBoth)
        #expect(viewModel.ledgerClaimRows.first { $0.id == Self.ctfKey }?.status == .unclaimed)
        #expect(viewModel.ledgerNeedsGas)
    }

    // a line of a claim in flight keeps the amount Claim found, as Windows'
    // rows do, whatever a read since says: on macOS the view model built on
    // coming back to Account reads the ledger again, and an account just paid
    // reads 0 there, or a pool it could not read lists none
    @Test func aLineDuringAClaimKeepsWhatClaimFound() async {
        let (client, viewModel) = await Self.loaded([Self.account(), Self.ctfAccount()])
        viewModel.claimLedger()
        client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        await Self.settle { viewModel.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch") }

        client.ledgerAnswer = [Self.paid]
        client.unavailablePools = [Self.ctfUnavailable]
        await viewModel.refreshSubnet()
        let rows = viewModel.ledgerClaimRows
        #expect(rows.first { $0.id == Self.key }?.amountRao == 3_241_000_000)
        #expect(rows.first { $0.id == Self.key }?.status == .sent)
        #expect(rows.first { $0.id == Self.ctfKey }?.amountRao == 144_076_980)
        #expect(rows.first { $0.id == Self.ctfKey }?.status == .pending)
        #expect(!rows.contains { $0.amountRao == 0 })
    }

    // the gas key sends one claim at a time: the sdk reads its pending nonce
    // as it signs, with no lock across a v1 and a v2 claim, so neither kind
    // starts while the other is in flight, and each sheet's Claim waits, as on
    // Linux and Windows
    @Test func aV1AndAV2ClaimNeverRunAtOnce() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        client.v1Claims = [
            SnEpochClaimInfo(epoch: 7, shareBps: 100, amountRao: 1_000_000_000, status: .claimable, claimOpenBlock: 0, expiryBlock: 0, txHash: ""),
        ]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.claimEnabled)
        #expect(viewModel.ledgerClaimEnabled)

        // a v2 claim in flight: no v1 claim
        viewModel.claimLedger()
        #expect(!viewModel.claimEnabled)
        viewModel.claimAll()
        #expect(client.v1ClaimCalls == 0)
        #expect(!viewModel.isClaiming)
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming && viewModel.claimEnabled }
        #expect(viewModel.claimEnabled)

        // a v1 claim in flight: no v2 claim
        viewModel.claimAll()
        #expect(client.v1ClaimCalls == 1)
        #expect(!viewModel.ledgerClaimEnabled)
        viewModel.claimLedger()
        #expect(client.claimCalls == 1)
        #expect(!viewModel.isLedgerClaiming)
        client.emitV1(.done)
        await Self.settle { !viewModel.isClaiming && viewModel.ledgerClaimEnabled }
        #expect(viewModel.ledgerClaimEnabled)
    }

    // the v1 sheet's figure during its claim is what the claim moves, the
    // epochs it sends as Claim found them, fixed until Done whatever a read
    // since says (as on Android and Linux)
    @Test func theV1FigureDuringAClaimIsWhatItMoves() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        func claim(_ epoch: Int64, _ rao: Int64, _ status: SnClaimStatus) -> SnEpochClaimInfo {
            SnEpochClaimInfo(epoch: epoch, shareBps: 100, amountRao: rao, status: status, claimOpenBlock: 0, expiryBlock: 0, txHash: "")
        }
        client.v1Claims = [claim(7, 1_000_000_000, .claimable), claim(9, 500_000_000, .claimable), claim(5, 2_000_000_000, .claimed)]
        let viewModel = EarningsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.claimFigureRao == 1_500_000_000)

        viewModel.claimAll()
        client.v1Claims = [claim(7, 1_000_000_000, .claimed), claim(9, 500_000_000, .claimed), claim(5, 2_000_000_000, .claimed)]
        await viewModel.refreshSubnet()
        #expect(viewModel.totalClaimableRao == 0)
        #expect(viewModel.claimFigureRao == 1_500_000_000)

        client.emitV1(.done)
        await Self.settle { !viewModel.isClaiming }
        #expect(viewModel.claimFigureRao == viewModel.totalClaimableRao)
    }

    // the v1 tile's Claim opens a v1 claim in flight whatever the last read
    // says, and its sheet lists the epochs Claim listed, as on Linux and
    // Windows: a read since changes none of them, and on macOS the view model
    // built on coming back to Account shows them though its claims read fails
    @Test func aV1ClaimInFlightOpensWithTheEpochsClaimListed() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        func claim(_ epoch: Int64, _ rao: Int64, _ status: SnClaimStatus) -> SnEpochClaimInfo {
            SnEpochClaimInfo(epoch: epoch, shareBps: 100, amountRao: rao, status: status, claimOpenBlock: 0, expiryBlock: 0, txHash: "")
        }
        let listed = [claim(9, 500_000_000, .claimable), claim(7, 1_000_000_000, .claimable), claim(5, 2_000_000_000, .claimed)]
        client.v1Claims = listed
        let session = EarningsSession(client: client)
        do {
            let first = EarningsViewModel(session: session)
            await first.refresh()
            #expect(first.claimTileEnabled)
            #expect(first.claimSheetClaims == listed)
            first.claimAll()
            #expect(first.isClaiming)
            // a read since: epoch 9 claimed on chain
            client.v1Claims = [claim(9, 500_000_000, .claimed), claim(7, 1_000_000_000, .claimable), claim(5, 2_000_000_000, .claimed)]
            await first.refreshSubnet()
            #expect(first.claims != listed)
            #expect(first.claimSheetClaims == listed)
        }
        client.emitV1(.confirmed(epoch: 9, txHash: "0x9", amountRao: 500_000_000))
        await Self.settle { session.claimProgress[9] == .confirmed(txHash: "0x9", amountRao: 500_000_000) }

        client.v1ClaimsFail = true
        let second = EarningsViewModel(session: session)
        await second.refresh()
        #expect(second.claims.isEmpty)
        #expect(second.claimTileEnabled)
        #expect(second.claimSheetClaims == listed)
        #expect(second.claimFigureRao == 1_500_000_000)
        // the count under the figure is the press's too, never 0 under it
        #expect(second.claimSheetClaimableCount == 2)
        #expect(!second.claimEnabled)

        client.emitV1(.done)
        await Self.settle { !second.isClaiming }
        #expect(!second.claimTileEnabled)
        #expect(second.claimSheetClaims.isEmpty)
        #expect(second.claimSheetClaimableCount == 0)
        #expect(session.claimListed.isEmpty)
        #expect(session.claimMovingRao == 0)
    }

    // a claim's Done reads the subnet again in every view model alive, the
    // one of each window that shows Account (the session is app-wide), so no
    // window keeps the balances the claim paid with Claim on them; one an
    // earlier visit built went with its screens and costs no read
    @Test func everyWindowsViewModelReadsAgainAtADone() async {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account()]
        let session = EarningsSession(client: client)
        weak var left: EarningsViewModel?
        do {
            let earlier = EarningsViewModel(session: session)
            left = earlier
            await earlier.refresh()
        }
        await Self.settle { left == nil }
        #expect(left == nil)
        let window = EarningsViewModel(session: session)
        await window.refresh()
        let other = EarningsViewModel(session: session)
        await other.refresh()
        #expect(other.ledgerClaimEnabled)

        window.claimLedger()
        let reads = client.ledgerReads
        client.ledgerAnswer = [Self.paid]
        client.emit(.done)
        await Self.settle { window.ledger == .loaded([Self.paid]) && other.ledger == .loaded([Self.paid]) }
        await Self.settle { false }
        #expect(client.ledgerReads == reads + 2)
        #expect(window.ledger == .loaded([Self.paid]))
        #expect(other.ledger == .loaded([Self.paid]))
        // nothing left: no window offers Claim on what the claim paid
        #expect(!window.ledgerClaimEnabled)
        #expect(!other.ledgerClaimEnabled)
    }

    // MARK: the app-wide session (owner, 2026-11-12: "make the session app-wide")

    /// The app's owner of the earnings session following a stand-in for the
    /// device manager's signed-in device (none: signed out), and the clients
    /// the sessions it has made so far read through, one per sign-in from
    /// `clients`, or a new one each when they run out.
    private static func appSessions(
        signedIn device: NSObject? = nil,
        clients: [FakeLedgerClient] = [],
        clock: FakeClock? = nil
    ) -> (sessions: EarningsSessions, devices: CurrentValueSubject<NSObject?, Never>, made: () -> [FakeLedgerClient]) {
        let sessions = EarningsSessions()
        let devices = CurrentValueSubject<NSObject?, Never>(device)
        var queue = clients
        var made: [FakeLedgerClient] = []
        sessions.follow(devices) { _ in
            let client = queue.isEmpty ? FakeLedgerClient() : queue.removeFirst()
            made.append(client)
            if let clock {
                return EarningsSession(client: client, sleep: { await clock.sleep($0) })
            }
            return EarningsSession(client: client)
        }
        return (sessions, devices, { made })
    }

    /// v1 claims: epoch 7 claimable, 1 α
    nonisolated private static let v1Claimable = [
        SnEpochClaimInfo(epoch: 7, shareBps: 100, amountRao: 1_000_000_000, status: .claimable, claimOpenBlock: 0, expiryBlock: 0, txHash: ""),
    ]

    /// a client with a connected coldkey, v2 claims configured, the pool's
    /// and capture the flag's accounts, a v1 epoch to claim and `wins`
    private static func walletClient(wins: [SnCtfWinInfo] = []) -> FakeLedgerClient {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        client.v1Claims = Self.v1Claimable
        client.ctfWinsAnswer = wins
        return client
    }

    // the app holds one session for the signed-in device: each window's
    // Account screens (macOS: File > New Window) get the same, the device
    // published again keeps it, and a device that is not the one signed in
    // gets none
    @Test func twoWindowsShareOneSession() async throws {
        let device = NSObject()
        let client = Self.walletClient()
        // a sign-in the device manager restored before the app followed it
        let app = Self.appSessions(signedIn: device, clients: [client])
        let session = try #require(app.sessions.session(for: device))
        #expect(app.sessions.current === session)
        #expect(app.made().count == 1)

        // two windows, each with its own Account screens' view model
        let first = EarningsViewModel(session: try #require(app.sessions.session(for: device)))
        let second = EarningsViewModel(session: try #require(app.sessions.session(for: device)))
        #expect(first.session === second.session)
        #expect(first.client === second.client)
        #expect(app.made().count == 1)

        // the device manager publishes the same device again: the same session
        app.devices.send(device)
        #expect(app.sessions.session(for: device) === session)
        #expect(app.made().count == 1)
        #expect(!session.ended)
        // another device's screens are not this session's
        #expect(app.sessions.session(for: NSObject()) == nil)

        // the windows' lines are the session's: one read shows in both
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        client.ctfWinsAnswer = [win]
        await first.refresh()
        await Self.settle { second.ctfWins == [win] }
        #expect(second.ctfWins == [win])
        #expect(first.ctfWins == [win])
    }

    // a v2 claim started in one window shows in the other at once and as it
    // goes on, holds Claim there, of either kind, until Done, and the other
    // window's tile opens it; its Done lands in both, and Claim follows the
    // read again in both
    @Test func aClaimInOneWindowShowsAndIsHeldInTheOther() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let device = NSObject()
        let client = Self.walletClient(wins: [win])
        let clock = FakeClock()
        let app = Self.appSessions(signedIn: device, clients: [client], clock: clock)
        let session = try #require(app.sessions.session(for: device))
        let first = EarningsViewModel(session: session)
        let second = EarningsViewModel(session: session)
        await first.refresh()
        await second.refresh()
        await Self.settle { second.ctfWins == [win] }
        #expect(first.ledgerClaimEnabled)
        #expect(second.ledgerClaimEnabled)
        #expect(second.claimEnabled)
        var secondChanges = 0
        let watch = second.objectWillChange.sink { _ in secondChanges += 1 }
        defer { watch.cancel() }

        first.claimLedger()
        #expect(client.claimCalls == 1)
        // the other window shows it at once, with what Claim named
        #expect(secondChanges > 0)
        #expect(second.isLedgerClaiming)
        #expect(second.ledgerClaimProgress == [Self.key: .queued, Self.ctfKey: .queued])
        #expect(second.ledgerClaimFigureRao == 3_241_000_000 + 144_076_980)
        #expect(second.ledgerClaimsBoth)
        // and holds Claim there, the v1 claim's too: the gas key sends one
        // claim at a time
        #expect(!second.ledgerClaimEnabled)
        #expect(!second.claimEnabled)
        second.claimLedger()
        second.claimAll()
        #expect(client.claimCalls == 1)
        #expect(client.v1ClaimCalls == 0)
        #expect(!second.isClaiming)
        // its tile's Claim opens the claim in flight, never a sheet started
        // over
        #expect(second.ledgerTile?.claimEnabled == true)
        second.resetLedgerClaimProgress()
        #expect(second.ledgerClaimProgress.count == 2)

        // each event shows in both windows
        client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        await Self.settle { second.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch") }
        #expect(second.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch"))
        #expect(first.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch"))
        #expect(second.ledgerClaimRows.map(\.status) == [.sent, .pending])
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        await Self.settle { second.ledgerClaimProgress[Self.ctfKey] == .confirmed(txHash: "0xbatch", amountRao: 144_076_980) }
        // still held until Done, in both
        #expect(!first.ledgerClaimEnabled)
        #expect(!second.claimEnabled)

        // the Done lands in both: each window reads the subnet again, the
        // session reads the wins once, and Claim follows the read again
        let ledgerReads = client.ledgerReads
        let winsReads = client.ctfWinsReads
        client.ledgerAnswer = [Self.paid, Self.ctfPaid]
        client.ctfWinsAnswer = []
        client.emit(.done)
        await Self.settle {
            first.ledger == .loaded([Self.paid, Self.ctfPaid]) && second.ledger == .loaded([Self.paid, Self.ctfPaid])
                && second.ctfWins.isEmpty && clock.sleeping == 1
        }
        #expect(!first.isLedgerClaiming)
        #expect(!second.isLedgerClaiming)
        #expect(first.ledgerClaimFinished)
        #expect(second.ledgerClaimFinished)
        #expect(client.ledgerReads == ledgerReads + 2)
        #expect(client.ctfWinsReads == winsReads + 1)
        #expect(first.ctfWins.isEmpty)
        #expect(second.ctfWins.isEmpty)
        #expect(!second.ledgerClaimEnabled)
        #expect(second.claimEnabled)
        #expect(first.claimEnabled)
        // the reads after it are the session's, one schedule for both windows
        #expect(clock.waits == [.seconds(30)])
    }

    // a v1 claim started in the other window is held in the first the same
    // way: it shows the epochs Claim listed, the figure and the count, its
    // tile opens it, and no claim of either kind starts until Done
    @Test func aV1ClaimInOneWindowShowsAndIsHeldInTheOther() async throws {
        let device = NSObject()
        let client = Self.walletClient()
        let app = Self.appSessions(signedIn: device, clients: [client])
        let session = try #require(app.sessions.session(for: device))
        let first = EarningsViewModel(session: session)
        let second = EarningsViewModel(session: session)
        await first.refresh()
        await second.refresh()
        #expect(first.claimEnabled)

        second.claimAll()
        #expect(client.v1ClaimCalls == 1)
        #expect(first.isClaiming)
        #expect(first.claimProgress == [7: .queued])
        #expect(first.claimSheetClaims == Self.v1Claimable)
        #expect(first.claimFigureRao == 1_000_000_000)
        #expect(first.claimSheetClaimableCount == 1)
        #expect(first.claimTileEnabled)
        #expect(!first.claimEnabled)
        #expect(!first.ledgerClaimEnabled)
        first.claimAll()
        first.claimLedger()
        #expect(client.v1ClaimCalls == 1)
        #expect(client.claimCalls == 0)
        #expect(!first.isLedgerClaiming)
        first.resetClaimProgress()
        #expect(first.claimProgress == [7: .queued])

        client.emitV1(.sent(epoch: 7, txHash: "0xv1"))
        await Self.settle { first.claimProgress[7] == .sent(txHash: "0xv1") }
        #expect(first.claimProgress[7] == .sent(txHash: "0xv1"))

        let ledgerReads = client.ledgerReads
        client.v1Claims = [SnEpochClaimInfo(epoch: 7, shareBps: 100, amountRao: 1_000_000_000, status: .claimed, claimOpenBlock: 0, expiryBlock: 0, txHash: "0xv1")]
        client.emitV1(.confirmed(epoch: 7, txHash: "0xv1", amountRao: 1_000_000_000))
        client.emitV1(.done)
        await Self.settle {
            first.claimFinished && second.claimFinished && first.claimableClaims.isEmpty && second.claimableClaims.isEmpty
        }
        #expect(first.claimFinished)
        #expect(second.claimFinished)
        #expect(client.ledgerReads == ledgerReads + 2)
        #expect(second.claimableClaims.isEmpty)
        #expect(!first.claimEnabled)
        #expect(!first.claimTileEnabled)
        #expect(first.ledgerClaimEnabled)
        #expect(second.ledgerClaimEnabled)
    }

    // a sign-out ends the session: the app drops it, and the claim's late
    // events, its Done and the reads after the last paying claim find nothing,
    // whatever window or view model is still about; the ended session starts
    // no claim or read
    @Test func aSignOutEndsTheSession() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let device = NSObject()
        let client = Self.walletClient(wins: [win])
        let clock = FakeClock()
        let app = Self.appSessions(signedIn: device, clients: [client], clock: clock)
        let session = try #require(app.sessions.session(for: device))
        let window = EarningsViewModel(session: session)
        await window.refresh()
        await Self.settle { window.ctfWins == [win] }

        // a claim that paid, whose reads after it are still to come
        window.claimLedger()
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.done)
        await Self.settle { !window.isLedgerClaiming && clock.sleeping == 1 }
        #expect(clock.sleeping == 1)
        // and a v1 claim in flight
        await window.refreshSubnet()
        window.claimAll()
        #expect(window.isClaiming)
        client.emitV1(.sent(epoch: 7, txHash: "0xv1"))
        await Self.settle { window.claimProgress[7] == .sent(txHash: "0xv1") }
        await Self.settle { false }

        // sign-out: the device manager's device goes
        app.devices.send(nil)
        #expect(session.ended)
        #expect(app.sessions.current == nil)
        #expect(app.sessions.session(for: device) == nil)

        // the claim's late events and its Done find nothing
        let ledgerReads = client.ledgerReads
        let winsReads = client.ctfWinsReads
        client.emitV1(.confirmed(epoch: 7, txHash: "0xv1", amountRao: 1_000_000_000))
        client.emitV1(.done)
        await Self.settle { false }
        #expect(session.claimProgress == [7: .sent(txHash: "0xv1")])
        #expect(client.ledgerReads == ledgerReads)
        // the reads after the paying claim stop
        clock.advance()
        await Self.settle { false }
        #expect(client.ctfWinsReads == winsReads)
        #expect(window.ctfWins == [win])
        // and it starts nothing more
        window.claimLedger()
        session.readCtfWins()
        await Self.settle { false }
        #expect(client.claimCalls == 1)
        #expect(client.v1ClaimCalls == 1)
        #expect(client.ctfWinsReads == winsReads)
    }

    // a session ended between claims starts no claim of either kind and no
    // read, whichever window asks, and a read out when it ended lands nowhere
    @Test func anEndedSessionStartsNothing() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let client = Self.walletClient()
        let session = EarningsSession(client: client)
        let window = EarningsViewModel(session: session)
        await window.refresh()
        await Self.settle { false }
        #expect(window.ledgerClaimEnabled)
        #expect(window.claimEnabled)

        var open: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { open = $0 }
        client.ctfWinsAnswer = [win]
        let winsReads = client.ctfWinsReads
        session.readCtfWins()
        await Self.settle { client.ctfWinsReads == winsReads + 1 }
        session.end()
        open?.yield()
        await Self.settle { false }
        #expect(session.ctfWins.isEmpty)

        window.claimLedger()
        window.claimAll()
        session.readCtfWins()
        await Self.settle { false }
        #expect(client.claimCalls == 0)
        #expect(client.v1ClaimCalls == 0)
        #expect(!session.isAnyClaiming)
        #expect(client.ctfWinsReads == winsReads + 1)
    }

    // a second account's sign-in gets a fresh session: no claim of the first
    // account's in flight, no lines until its own first read answers, and
    // Claim not held by the first account's claim, whose late events never
    // reach it; after a sign-out, or with no sign-out between
    @Test func aSecondAccountsSignInGetsAFreshSession() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let first = NSObject()
        let firstClient = Self.walletClient(wins: [win])
        let secondClient = Self.walletClient()
        let thirdClient = Self.walletClient()
        let app = Self.appSessions(signedIn: first, clients: [firstClient, secondClient, thirdClient])
        let firstSession = try #require(app.sessions.session(for: first))
        let firstWindow = EarningsViewModel(session: firstSession)
        await firstWindow.refresh()
        await Self.settle { firstWindow.ctfWins == [win] }
        firstWindow.claimLedger()
        #expect(firstSession.isLedgerClaiming)

        app.devices.send(nil)
        let second = NSObject()
        app.devices.send(second)
        let secondSession = try #require(app.sessions.session(for: second))
        #expect(secondSession !== firstSession)
        #expect(firstSession.ended)
        #expect(!secondSession.ended)
        #expect(app.sessions.session(for: first) == nil)
        #expect(app.made().count == 2)

        let secondWindow = EarningsViewModel(session: secondSession)
        #expect(!secondWindow.isLedgerClaiming)
        #expect(secondWindow.ledgerClaimProgress.isEmpty)
        #expect(secondWindow.ctfWins.isEmpty)
        await secondWindow.refresh()
        #expect(secondWindow.ledgerClaimEnabled)
        #expect(secondWindow.claimEnabled)
        secondWindow.claimLedger()
        #expect(secondClient.claimCalls == 1)
        // the first account's claim goes on in the sdk: none of it reaches
        // the second account's
        firstClient.emit(.confirmed(noId: 1, index: 42, txHash: "0xfirst", amountRao: 3_241_000_000))
        firstClient.emit(.done)
        await Self.settle { false }
        #expect(secondWindow.ledgerClaimProgress == [Self.key: .queued, Self.ctfKey: .queued])
        #expect(secondWindow.isLedgerClaiming)

        // a device that replaces the signed-in one with no sign-out between
        // ends its session too, and gets a fresh one
        let third = NSObject()
        app.devices.send(third)
        let thirdSession = try #require(app.sessions.session(for: third))
        #expect(secondSession.ended)
        #expect(thirdSession !== secondSession)
        #expect(!thirdSession.isAnyClaiming)
        #expect(app.sessions.session(for: second) == nil)
        #expect(app.made().count == 3)
    }

    // iOS: the tab view keeps its Account screens, so one view model draws
    // the app's session for the whole sign-in, as it drew the tab view's: a
    // claim's sheet swiped away and opened again shows it, Claim waits until
    // Done, the Done reads again, and the wins are read on the schedule; a
    // sign-out ends the reads, and the next sign-in's tab view starts over
    @Test func theTabViewDrawsTheAppsSession() async throws {
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is", epoch: 10))
        let device = NSObject()
        let client = Self.walletClient(wins: [win])
        let clock = FakeClock()
        let app = Self.appSessions(clients: [client], clock: clock)
        #expect(app.sessions.current == nil)
        app.devices.send(device)
        let tab = EarningsViewModel(session: try #require(app.sessions.session(for: device)))
        await tab.refresh()
        await Self.settle { tab.ctfWins == [win] }

        tab.claimLedger()
        client.emit(.sent(noId: 1, index: 42, txHash: "0xbatch"))
        await Self.settle { tab.ledgerClaimProgress[Self.key] == .sent(txHash: "0xbatch") }
        // the sheet swiped away, and opened again from the tile
        #expect(tab.ledgerTile?.claimEnabled == true)
        tab.resetLedgerClaimProgress()
        #expect(tab.ledgerClaimProgress == [Self.key: .sent(txHash: "0xbatch"), Self.ctfKey: .queued])
        #expect(!tab.ledgerClaimEnabled)
        tab.claimLedger()
        #expect(client.claimCalls == 1)

        let ledgerReads = client.ledgerReads
        client.ledgerAnswer = [Self.paid, Self.ctfPaid]
        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xbatch", amountRao: 3_241_000_000))
        client.emit(.confirmed(noId: Self.ctfNoId, index: 7, txHash: "0xbatch", amountRao: 144_076_980))
        client.emit(.done)
        // the server still says unclaimed at Done
        await Self.settle { tab.ledger == .loaded([Self.paid, Self.ctfPaid]) && clock.sleeping == 1 }
        #expect(client.ledgerReads == ledgerReads + 1)
        #expect(tab.ctfWins == [win])
        client.ctfWinsAnswer = []
        clock.advance()
        await Self.settle { tab.ctfWins.isEmpty && clock.sleeping == 1 }
        #expect(tab.ctfWins.isEmpty)
        #expect(clock.waits == [.seconds(30), .seconds(30)])

        // sign-out: the reads stop
        let winsReads = client.ctfWinsReads
        app.devices.send(nil)
        clock.advance()
        await Self.settle { false }
        #expect(client.ctfWinsReads == winsReads)
        // the next sign-in's tab view: a fresh session
        let next = NSObject()
        app.devices.send(next)
        let nextTab = EarningsViewModel(session: try #require(app.sessions.session(for: next)))
        #expect(nextTab.session !== tab.session)
        #expect(nextTab.ledgerClaimProgress.isEmpty)
        #expect(nextTab.ctfWins.isEmpty)
    }

    // MARK: localization

    /// the strings the v2 tile and dialog add
    private static let newStrings = [
        "Settlement v2",
        "Claimable",
        "Earned",
        "Paid",
        "Pending: +%@, awaiting finalization",
        "Unavailable",
        "Pool %lld",
    ]

    // …/apple/app/networkTests/SnLedgerTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func catalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: appRoot.appendingPathComponent("network/Shared/Resources/Localizable.xcstrings"))
        let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(catalog?["strings"] as? [String: Any])
    }

    // §11: the new strings, and "Transaction" the explorer link reuses, are
    // translated in every locale the catalog ships, with their placeholders
    @Test func theV2StringsAreTranslatedInEveryLocale() throws {
        let strings = try Self.catalogStrings()
        var locales = Set<String>()
        for case let entry as [String: Any] in strings.values {
            if let localizations = entry["localizations"] as? [String: Any] {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(locales.contains("zh-Hans"))

        for key in Self.newStrings + ["Transaction"] {
            let entry = try #require(strings[key] as? [String: Any], "the catalog has no \(key)")
            #expect(entry["extractionState"] as? String != "stale", "\(key) is stale")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            var missing: [String] = []
            for locale in locales.sorted() {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any]
                guard let value = unit?["value"] as? String, !value.isEmpty else {
                    missing.append(locale)
                    continue
                }
                for placeholder in ["%@", "%lld"] where key.contains(placeholder) {
                    #expect(value.contains(placeholder), "\(key) in \(locale) lost \(placeholder)")
                }
            }
            #expect(missing.isEmpty, "\(key) not translated: \(missing)")
        }
    }
}

/// A scripted EarningsClient for the v2 layer: a connected coldkey, the
/// ledger's current answer (nil: it cannot be read) and the pools it could
/// not read, the relay's answer, the latest capture the flag win, and a v2
/// claim the test drives event by event, as the SDK reports it.
private final class FakeLedgerClient: EarningsClient {

    var wallet: SnWalletInfo? = SnWalletInfo(coldkeySs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY", clientId: "", setAtMillis: 0)
    var chain = SnLedgerChainInfo.unconfigured
    var ledgerAnswer: [SnLedgerAccountInfo]? = []
    var unavailablePools: [SnLedgerUnavailablePool] = []
    var relayAnswer: SnClaimStatusInfo?
    /// the wins' next answer: nil is a read that failed
    var ctfWinsAnswer: [SnCtfWinInfo]? = []
    /// the answers of the next reads of the wins, one each, before
    /// ctfWinsAnswer: a server that still says unclaimed
    var ctfWinsAnswers: [[SnCtfWinInfo]?] = []
    /// the client the wins' next answer is for: "" for the network's answer,
    /// a client's id for this client's alone (the sdk's read with the client
    /// token, or an older server's)
    var ctfWinsClientId = ""
    /// the same for the next reads, one each, before ctfWinsClientId
    var ctfWinsClientIds: [String] = []
    /// holds the next read's answer back until the test yields to it
    var ctfWinGate: AsyncStream<Void>?
    private(set) var ctfWinsReads = 0
    private(set) var ledgerReads = 0
    var gasTao: Double = 1
    var v1Claims: [SnEpochClaimInfo] = []
    /// the claims read fails
    var v1ClaimsFail = false
    private(set) var v1ClaimCalls = 0
    private(set) var claimCalls = 0
    private var onClaimEvent: ((SnLedgerClaimEvent) -> Void)?
    private var onV1ClaimEvent: ((SnClaimEvent) -> Void)?

    private struct Unsupported: Error {}
    private struct LedgerUnavailable: Error {}

    /// reports a claim event of the running v2 claim, as the SDK does
    func emit(_ event: SnLedgerClaimEvent) {
        onClaimEvent?(event)
    }

    /// reports a claim event of the running v1 claim, as the SDK does
    func emitV1(_ event: SnClaimEvent) {
        onV1ClaimEvent?(event)
    }

    func validateSs58(_ address: String) -> Bool { true }
    func shortSs58(_ address: String) -> String { address }
    func formatAlpha(rao: Int64) -> String { "\(rao)" }
    func formatShareBps(_ shareBps: Int64) -> String { "\(shareBps)" }
    func walletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult { throw Unsupported() }
    func validateWallet(_ address: String) async throws -> SnWalletValidation { throw Unsupported() }
    func cachedWallet() -> SnWalletInfo? { wallet }
    func fetchWallet() async throws -> SnWalletInfo? { wallet }
    func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo { throw Unsupported() }
    func observeWallet(_ onChange: @escaping (SnWalletInfo?) -> Void) -> EarningsSubscription { EarningsSubscription {} }
    func syncChainSettings() async throws {}
    func gasKey() -> SnGasKeyInfo? {
        SnGasKeyInfo(address: "0x1111111111111111111111111111111111111111", mirrorSs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY")
    }
    func gasBalanceTao() async throws -> Double { gasTao }
    func claims() async throws -> (claims: [SnEpochClaimInfo], totalClaimableRao: Int64, schedule: SnEpochScheduleInfo?) {
        if v1ClaimsFail {
            throw Unsupported()
        }
        return (v1Claims, v1Claims.filter { $0.status == .claimable }.reduce(0) { $0 + $1.amountRao }, nil)
    }
    func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void) {
        v1ClaimCalls += 1
        onV1ClaimEvent = onEvent
    }
    func ledgerChain() -> SnLedgerChainInfo { chain }
    func ledgerAccounts() async throws -> SnLedgerAccountsInfo {
        ledgerReads += 1
        guard let ledgerAnswer else {
            throw LedgerUnavailable()
        }
        return SnLedgerAccountsInfo(accounts: ledgerAnswer, unavailablePools: unavailablePools)
    }
    func ledgerClaim(onEvent: @escaping (SnLedgerClaimEvent) -> Void) {
        claimCalls += 1
        onClaimEvent = onEvent
    }
    func claimStatus() async -> SnClaimStatusInfo? { relayAnswer }
    func ctfUnclaimedWins() async -> SnCtfWinsAnswer? {
        ctfWinsReads += 1
        // the server answers as the read starts; a gate holds the answer back
        let answer = ctfWinsAnswers.isEmpty ? ctfWinsAnswer : ctfWinsAnswers.removeFirst()
        let clientId = ctfWinsClientIds.isEmpty ? ctfWinsClientId : ctfWinsClientIds.removeFirst()
        if let gate = ctfWinGate {
            ctfWinGate = nil
            for await _ in gate {
                break
            }
        }
        return answer.map { SnCtfWinsAnswer(wins: $0, clientId: clientId) }
    }
    func accountEpochs() async throws -> [AccountEpochInfo] { [] }
    func topMe() async throws -> SnTopMeResultInfo { throw EarningsClientError.emptyResult }
}

/// The tests' clock for the view model's waits (its `sleep`): each wait asked
/// for is recorded and lasts until the test moves the clock on.
@MainActor
private final class FakeClock {

    /// every wait asked for, in order
    private(set) var waits: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    /// the waits not over yet
    var sleeping: Int {
        sleepers.count
    }

    func sleep(_ duration: Duration) async {
        waits.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// ends every wait not over yet
    func advance() {
        let woken = sleepers
        sleepers = []
        for sleeper in woken {
            sleeper.resume()
        }
    }
}
