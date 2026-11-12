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
//  no other; a capture the flag balance under the relay's transfer floor
//  waits; one claim claims both pools ("Claim both"), as the SDK's one batch
//  transaction, within one claim's gas reserve; the relay's claim sheet lists
//  each pool's account; and entries without a kind, from a server that
//  predates it, read exactly as before.
//

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
        #expect(SnLedgerTilePresentation.of(load: .loaded([account]), claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
            balances: .pools([Self.row(account)]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .loaded([account]), claimConfigured: false, isClaiming: false) == SnLedgerTilePresentation(
            balances: .pools([Self.row(account)]),
            showsClaim: false,
            claimEnabled: false,
            showsPools: false
        ))
    }

    // CL-2: nothing claimable, or a v2 claim running, leaves Claim disabled
    @Test func nothingClaimableOrAClaimRunningDisablesClaim() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid]), claimConfigured: true, isClaiming: false)?.claimEnabled == false)
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account()]), claimConfigured: true, isClaiming: true)?.claimEnabled == false)
        // one claimable pool of two is enough
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid, Self.account(noId: 2)]), claimConfigured: true, isClaiming: false)?.claimEnabled == true)
    }

    // CL-2: a ledger that cannot be read is "Unavailable" with Claim
    // disabled, never 0; before activation it is no tile at all
    @Test func anUnreadableLedgerIsUnavailableNeverZero() {
        #expect(SnLedgerTilePresentation.of(load: .unavailable, claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
            balances: .unavailable,
            showsClaim: true,
            claimEnabled: false,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .unavailable, claimConfigured: false, isClaiming: false) == nil)
    }

    // CL-2: no account, or no read yet, is no tile
    @Test func noAccountOrNoReadYetIsNoTile() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([]), claimConfigured: true, isClaiming: false) == nil)
        #expect(SnLedgerTilePresentation.of(load: .loaded([]), claimConfigured: false, isClaiming: false) == nil)
        #expect(SnLedgerTilePresentation.of(load: .loading, claimConfigured: true, isClaiming: false) == nil)
    }

    // CL-2: with more than one pool each account names its pool, "Pool 1",
    // and Claim is never "Claim both" without capture the flag
    @Test func severalPoolsNameTheirPool() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account()]), claimConfigured: true, isClaiming: false)?.showsPools == false)
        let second = Self.account(noId: 2, index: 3)
        let tile = SnLedgerTilePresentation.of(load: .loaded([Self.account(), second]), claimConfigured: true, isClaiming: false)
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
        #expect(viewModel.ledgerTile?.claimEnabled == false)
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

    // §11 (v2 claim): needs_gas shows the gas top-up and keeps Claim off
    // until the dialog starts over
    @Test func needsGasShowsTheGasTopUp() async {
        let (client, viewModel) = await Self.loaded([Self.account()])
        #expect(!viewModel.ledgerNeedsGas)

        viewModel.claimLedger()
        client.emit(.failed(noId: 1, index: 42, message: "needs_gas: this claim needs up to 0.0126 TAO of gas; send TAO to the gas key"))
        client.emit(.done)
        await Self.settle { !viewModel.isLedgerClaiming }

        #expect(viewModel.ledgerClaimFailures.map(\.failure) == [.needsGas])
        #expect(viewModel.ledgerClaimRows.map(\.status) == [.failed])
        #expect(viewModel.ledgerNeedsGas)
        #expect(!viewModel.ledgerClaimEnabled)
        #expect(viewModel.ledgerClaimFinished)

        viewModel.resetLedgerClaimProgress()
        #expect(!viewModel.ledgerNeedsGas)
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
    // "Capture the flag", the operator's pool beside one "Provider pool", and
    // a pool with none beside it its number, as before
    @Test func eachPoolIsNamedFromItsKind() {
        #expect(SnLedgerPoolName.of(kind: .pool, noId: 1, besideCtf: false) == .pool(noId: 1))
        #expect(SnLedgerPoolName.of(kind: .pool, noId: 1, besideCtf: true) == .providerPool)
        #expect(SnLedgerPoolName.of(kind: .ctf, noId: Self.ctfNoId, besideCtf: true) == .captureTheFlag)
        // a pool the operator could not read counts as beside
        let pools = SnLedgerPools(accounts: [Self.account()], unavailablePools: [Self.ctfUnavailable])
        #expect(pools.besideCtf)
        #expect(pools.name(Self.account()) == .providerPool)
        #expect(pools.name(Self.ctfUnavailable) == .captureTheFlag)
        #expect(!SnLedgerPools(accounts: [Self.account(), Self.account(noId: 2, index: 3)], unavailablePools: []).besideCtf)
    }

    // §10: the capture the flag account is a row of its own under the
    // provider pool's, both named, and Claim claims both
    @Test func aCaptureTheFlagAccountIsARowOfItsOwn() {
        let pool = Self.account()
        let ctf = Self.ctfAccount()
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, ctf]), claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
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
        #expect(SnLedgerTilePresentation.of(load: .loaded([ctf]), claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
            balances: .pools([SnLedgerPoolRow(name: .captureTheFlag, balance: .account(ctf))]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: true
        ))
        // both, but only one has something to claim: Claim
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid, ctf]), claimConfigured: true, isClaiming: false)?.claimsBoth == false)
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, Self.ctfPaid]), claimConfigured: true, isClaiming: false)?.claimsBoth == false)
    }

    // §9.1, §10: a pool the operator could not read is "Unavailable right
    // now" in its own row, never 0, and hides no other: the others claim as
    // usual
    @Test func anUnavailablePoolHidesNoOther() {
        let pool = Self.account()
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool], unavailablePools: [Self.ctfUnavailable]), claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
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
        #expect(SnLedgerTilePresentation.of(load: .loaded([ctf], unavailablePools: [providerPool]), claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
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
        #expect(SnLedgerTilePresentation.of(load: .loaded([], unavailablePools: [providerPool]), claimConfigured: true, isClaiming: false) == SnLedgerTilePresentation(
            balances: .pools([SnLedgerPoolRow(name: .pool(noId: 1), balance: .unavailable(providerPool))]),
            showsClaim: true,
            claimEnabled: false,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .loaded([], unavailablePools: [providerPool]), claimConfigured: false, isClaiming: false) == nil)
    }

    // §10: beside capture the flag a balance under the relay's transfer floor
    // waits, "Below the claim minimum", and Claim is not "Claim both"; without
    // a floor the claim's preflight decides, and before capture the flag a
    // pool account keeps the rule it had
    @Test func aBalanceUnderTheFloorWaitsBesideCaptureTheFlag() {
        let pool = Self.account()
        let oneSlot = Self.ctfAccount(claimableRao: 48_025_660)
        let tile = SnLedgerTilePresentation.of(load: .loaded([pool, oneSlot]), claimConfigured: true, isClaiming: false, transferFloorRao: Self.floorRao)
        #expect(tile?.balances == .pools([
            SnLedgerPoolRow(name: .providerPool, balance: .account(pool)),
            SnLedgerPoolRow(name: .captureTheFlag, balance: .account(oneSlot), underFloor: true),
        ]))
        #expect(tile?.claimEnabled == true)
        #expect(tile?.claimsBoth == false)
        // nothing else to claim: no claim
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.paid, oneSlot]), claimConfigured: true, isClaiming: false, transferFloorRao: Self.floorRao)?.claimEnabled == false)
        // the floor or more: both
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, Self.ctfAccount(claimableRao: Self.floorRao)]), claimConfigured: true, isClaiming: false, transferFloorRao: Self.floorRao)?.claimsBoth == true)
        // no floor without a price
        #expect(SnLedgerTilePresentation.of(load: .loaded([pool, oneSlot]), claimConfigured: true, isClaiming: false, transferFloorRao: 0)?.claimsBoth == true)
        // before capture the flag a pool account under it is claimable, as it
        // was
        let smallPool = Self.account(claimableRao: 1_000_000)
        #expect(SnLedgerTilePresentation.of(load: .loaded([smallPool]), claimConfigured: true, isClaiming: false, transferFloorRao: Self.floorRao) == SnLedgerTilePresentation(
            balances: .pools([Self.row(smallPool)]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: false
        ))
        let before = SnLedgerPools(accounts: [smallPool], unavailablePools: [], transferFloorRao: Self.floorRao)
        #expect(!before.ctfRules)
        #expect(SnLedgerClaimRow.of(smallPool, progress: nil, chain: Self.configured, pools: before).status == .unclaimed)
        // beside it, it waits too; and so it does beside a pool that could
        // not be read
        let beside = SnLedgerPools(accounts: [smallPool, oneSlot], unavailablePools: [], transferFloorRao: Self.floorRao)
        #expect(SnLedgerClaimRow.of(smallPool, progress: nil, chain: Self.configured, pools: beside).status == .underFloor)
        #expect(SnLedgerClaimRow.of(oneSlot, progress: nil, chain: Self.configured, pools: beside).status == .underFloor)
        let partial = SnLedgerPools(accounts: [smallPool], unavailablePools: [SnLedgerUnavailablePool(vault: Self.vault2, noId: 2)], transferFloorRao: Self.floorRao)
        #expect(partial.ctfRules)
        #expect(SnLedgerClaimRow.of(smallPool, progress: nil, chain: Self.configured, pools: partial).status == .underFloor)
        // a claim's progress overrides it
        #expect(SnLedgerClaimRow.of(oneSlot, progress: .underFloor, chain: Self.configured, pools: beside).status == .underFloor)
        #expect(SnLedgerClaimRow.of(oneSlot, progress: .sent(txHash: "0xabc"), chain: Self.configured, pools: beside).status == .sent)
    }

    // §10: the sdk claims every account with something to claim, and the
    // chain refuses one under the floor (not_claimable: AmountTooLow): beside
    // capture the flag it waits, below the claim minimum, and is no failure,
    // whether the sheet left it out by the relay's floor or knew no floor;
    // before capture the flag the refusal is the failure it was
    @Test func theClaimsRefusalUnderTheFloorIsNoFailureBesideCaptureTheFlag() async {
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

        // before capture the flag
        let small = Self.account(claimableRao: 1_000_000)
        let (oldClient, oldModel) = await Self.loaded([small])
        oldModel.claimLedger()
        oldClient.emit(.failed(noId: 1, index: 42, message: amountTooLow))
        oldClient.emit(.done)
        await Self.settle { !oldModel.isLedgerClaiming }
        #expect(oldModel.ledgerClaimFailures.map(\.failure) == [.message(amountTooLow)])
        #expect(oldModel.ledgerClaimRows.map(\.status) == [.failed])
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
            SnLedgerClaimRow(id: SnLedgerAccountKey(noId: Self.ctfNoId, index: 0), name: .captureTheFlag, amountRao: 0, status: .unavailable, explorerUrl: nil),
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

    // §10: the relay's claim sheet lists each pool's account beside capture
    // the flag (Android's rows): Pending, Below the claim minimum under the
    // floor, Claimed with URnetwork's transaction, a pool it could not read;
    // before capture the flag it keeps its one balance
    @Test func theRelaySheetListsEachPoolBesideCaptureTheFlag() {
        let coldkey = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        let before = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000)]
        )
        #expect(SnClaimRelayRow.rows(before).isEmpty)

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
                SnClaimRelayAccountInfo(coldkeySs58: replaced, noId: 2),
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

        // a whole answer with one operator pool: the total alone, as before
        client.relayAnswer = SnClaimStatusInfo(
            coldkeySs58: coldkey,
            claimableRao: 3_241_000_000,
            showsTile: true,
            accounts: [SnClaimRelayAccountInfo(coldkeySs58: coldkey, noId: 1, claimableRao: 3_241_000_000)]
        )
        await viewModel.refreshClaimStatus()
        #expect(viewModel.ledgerTileWithRelay?.balances == .claimable(3_241_000_000))
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

    // §10 (optional line): the slot this device won last, from GET
    // /sn/ctf/client; an answer that could not be read draws no line, and
    // neither does a role this build does not know
    @Test func theSdkWinReadGivesTheLatestWin() throws {
        let win = SdkSnCtfWin()
        win.role = SdkSnCtfRoleExtender
        win.country = "la"
        win.epoch = 9
        let result = SdkSnCtfClientResult()
        result.latestWin = win
        #expect(EarningsSdkClient.ctfLatestWin(from: result) == SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la"))
        #expect(EarningsSdkClient.ctfLatestWin(from: SdkSnCtfClientResult()) == nil)
        result.error = Self.snError(code: SdkSnErrorCodeCtfUnavailable, message: "401 Unauthorized")
        #expect(EarningsSdkClient.ctfLatestWin(from: result) == nil)

        #expect(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is")?.role == .provider)
        #expect(SnCtfWinInfo(role: "observer", country: "is") == nil)
        #expect(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "") == nil)
    }

    // §10 (optional line): the refresh reads the win beside the ledger, and
    // a later read without one draws no line
    @Test func theRefreshReadsTheLatestWin() async throws {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleProvider, country: "is"))
        client.ctfWinAnswer = win
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        await Self.settle { viewModel.ctfWin == win }
        #expect(viewModel.ctfWin == win)

        client.ctfWinAnswer = nil
        await viewModel.refresh()
        await Self.settle { viewModel.ctfWin == nil }
        #expect(viewModel.ctfWin == nil)
    }

    // §10 (optional line): the win's read never holds up the refresh, which
    // the sdk can wait on for up to a minute; the line follows once it lands
    @Test func theWinsReadNeverHoldsUpTheRefresh() async throws {
        let client = FakeLedgerClient()
        client.chain = Self.configured
        client.ledgerAnswer = [Self.account(), Self.ctfAccount()]
        let win = try #require(SnCtfWinInfo(role: SdkSnCtfRoleExtender, country: "la"))
        client.ctfWinAnswer = win
        var open: AsyncStream<Void>.Continuation?
        client.ctfWinGate = AsyncStream { open = $0 }
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.loadedOnce)
        #expect(!viewModel.isLoading)
        #expect(viewModel.ledger == .loaded([Self.account(), Self.ctfAccount()]))
        #expect(viewModel.ctfWin == nil)

        open?.yield()
        await Self.settle { viewModel.ctfWin == win }
        #expect(viewModel.ctfWin == win)
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
    var ctfWinAnswer: SnCtfWinInfo?
    /// holds the win's read until the test yields to it
    var ctfWinGate: AsyncStream<Void>?
    private(set) var ledgerReads = 0
    var gasTao: Double = 1
    var v1Claims: [SnEpochClaimInfo] = []
    private(set) var v1ClaimCalls = 0
    private(set) var claimCalls = 0
    private var onClaimEvent: ((SnLedgerClaimEvent) -> Void)?

    private struct Unsupported: Error {}
    private struct LedgerUnavailable: Error {}

    /// reports a claim event of the running v2 claim, as the SDK does
    func emit(_ event: SnLedgerClaimEvent) {
        onClaimEvent?(event)
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
        (v1Claims, v1Claims.filter { $0.status == .claimable }.reduce(0) { $0 + $1.amountRao }, nil)
    }
    func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void) {
        v1ClaimCalls += 1
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
    func ctfLatestWin() async -> SnCtfWinInfo? {
        if let ctfWinGate {
            for await _ in ctfWinGate {
                break
            }
        }
        return ctfWinAnswer
    }
    func accountEpochs() async throws -> [AccountEpochInfo] { [] }
    func topMe() async throws -> SnTopMeResultInfo { throw EarningsClientError.emptyResult }
}
