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

    /// pool 1's account: 5 α finalized, 1.759 α paid, 3.241 α claimable
    nonisolated private static func account(
        noId: Int64 = 1,
        index: Int64 = 42,
        finalizedRao: Int64 = 5_000_000_000,
        claimableRao: Int64 = 3_241_000_000,
        paidRao: Int64 = 1_759_000_000,
        pending: Bool = false,
        pendingRao: Int64 = 0
    ) -> SnLedgerAccountInfo {
        SnLedgerAccountInfo(
            vault: vault2,
            noId: noId,
            index: index,
            finalizedRao: finalizedRao,
            claimableRao: claimableRao,
            paidRao: paidRao,
            pending: pending,
            pendingRao: pendingRao
        )
    }

    /// the same account once all of it is paid
    nonisolated private static let paid = account(claimableRao: 0, paidRao: 5_000_000_000)

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

        #expect(try EarningsSdkClient.ledgerAccounts(from: result) == [
            Self.account(pending: true, pendingRao: 5_500_000_000),
            Self.account(noId: 2, index: 7, finalizedRao: 0, claimableRao: 0, paidRao: 0, pending: true, pendingRao: 1_000_000_000),
        ])
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
        #expect(try EarningsSdkClient.ledgerAccounts(from: none).isEmpty)
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
            balances: .accounts([account]),
            showsClaim: true,
            claimEnabled: true,
            showsPools: false
        ))
        #expect(SnLedgerTilePresentation.of(load: .loaded([account]), claimConfigured: false, isClaiming: false) == SnLedgerTilePresentation(
            balances: .accounts([account]),
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

    // CL-2: with more than one pool each account names its pool
    @Test func severalPoolsNameTheirPool() {
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account()]), claimConfigured: true, isClaiming: false)?.showsPools == false)
        #expect(SnLedgerTilePresentation.of(load: .loaded([Self.account(), Self.account(noId: 2, index: 3)]), claimConfigured: true, isClaiming: false)?.showsPools == true)
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
            SnLedgerClaimRow(id: Self.key, amountRao: 3_241_000_000, status: .sent, explorerUrl: link),
        ])

        client.emit(.confirmed(noId: 1, index: 42, txHash: "0xabc", amountRao: 3_240_999_999))
        await Self.settle { viewModel.ledgerClaimProgress[Self.key] == .confirmed(txHash: "0xabc", amountRao: 3_240_999_999) }
        #expect(viewModel.ledgerClaimRows == [
            SnLedgerClaimRow(id: Self.key, amountRao: 3_240_999_999, status: .claimed, explorerUrl: link),
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
            SnLedgerClaimRow(id: Self.key, amountRao: 0, status: .claimed, explorerUrl: nil),
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
/// ledger's current answer (nil: it cannot be read), and a v2 claim the test
/// drives event by event, as the SDK reports it.
private final class FakeLedgerClient: EarningsClient {

    var wallet: SnWalletInfo? = SnWalletInfo(coldkeySs58: "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY", clientId: "", setAtMillis: 0)
    var chain = SnLedgerChainInfo.unconfigured
    var ledgerAnswer: [SnLedgerAccountInfo]? = []
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
    func ledgerAccounts() async throws -> [SnLedgerAccountInfo] {
        ledgerReads += 1
        guard let ledgerAnswer else {
            throw LedgerUnavailable()
        }
        return ledgerAnswer
    }
    func ledgerClaim(onEvent: @escaping (SnLedgerClaimEvent) -> Void) {
        claimCalls += 1
        onClaimEvent = onEvent
    }
    func accountEpochs() async throws -> [AccountEpochInfo] { [] }
    func head() async throws -> SnHeadInfo? { nil }
}
