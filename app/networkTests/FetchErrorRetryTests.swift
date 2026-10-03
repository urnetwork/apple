//
//  FetchErrorRetryTests.swift
//  networkTests
//
//  A failed fetch was shown as real data: Account and Earnings showed 0
//  points, the Earnings history said "No epochs yet", a failed wallet read
//  offered to connect a wallet, and the USDC payout wallet card disappeared.
//  Each section now reports the failure (SectionLoad.failed, shown with a
//  Retry) while it has nothing fetched to show, keeps what it has when a
//  refresh fails, and clears the failure when a retry succeeds.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct FetchErrorRetryTests {

    private struct FetchError: Error {}

    // MARK: account points

    private static func pointsResult(_ nanoPoints: [(event: String, value: Int64)]) -> SdkAccountPointsResult {
        let list = SdkAccountPointsList()
        for (event, value) in nanoPoints {
            let point = SdkAccountPoint()
            point.event = event
            point.pointValue = value
            list.add(point)
        }
        let result = SdkAccountPointsResult()
        result.accountPoints = list
        return result
    }

    @Test func aFailedPointsFetchIsNotZeroPoints() async {
        let store = AccountPointsStore(api: nil, fetchAccountPoints: { throw FetchError() })

        await store.fetchAccountPoints()

        #expect(store.load == .failed)
        #expect(!store.isLoading)
    }

    @Test func aPointsRetryThatSucceedsShowsThePoints() async {
        var attempts = 0
        let store = AccountPointsStore(api: nil, fetchAccountPoints: {
            attempts += 1
            if attempts == 1 {
                throw FetchError()
            }
            return Self.pointsResult([("payout", 2_000_000_000)])
        })

        await store.fetchAccountPoints()
        #expect(store.load == .failed)

        await store.fetchAccountPoints()
        #expect(store.load == .loaded)
        #expect(store.netPoints == SdkNanoPointsToPoints(2_000_000_000))
    }

    @Test func noPointsYetIsAnAnswerNotAFailure() async {
        let store = AccountPointsStore(api: nil, fetchAccountPoints: { SdkAccountPointsResult() })

        await store.fetchAccountPoints()

        #expect(store.load == .loaded)
        #expect(store.netPoints == 0)
    }

    @Test func loadedPointsStayWhenARefreshFails() async {
        var attempts = 0
        let store = AccountPointsStore(api: nil, fetchAccountPoints: {
            attempts += 1
            if attempts == 2 {
                throw FetchError()
            }
            return Self.pointsResult([("payout_linked_account", 1_000_000_000)])
        })

        await store.fetchAccountPoints()
        await store.fetchAccountPoints()

        #expect(store.load == .loaded)
        #expect(store.referralPoints == SdkNanoPointsToPoints(1_000_000_000))
    }

    // MARK: earnings history and wallet

    @Test func aFailedEpochReadIsNotNoEpochsYet() async {
        let client = FakeEarningsClient()
        client.epochsError = FetchError()
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.epochs.isEmpty)
        #expect(viewModel.historyLoad == .failed)
    }

    @Test func anEpochRetryThatSucceedsClearsTheFailure() async {
        let client = FakeEarningsClient()
        client.epochsError = FetchError()
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.historyLoad == .failed)

        client.epochsError = nil
        await viewModel.refresh()
        // an empty history that was read is the real "No epochs yet"
        #expect(viewModel.historyLoad == .loaded)

        client.epochRows = [Self.epoch(7)]
        await viewModel.refresh()
        #expect(viewModel.epochs.map(\.epoch) == [7])
        #expect(viewModel.historyLoad == .loaded)
    }

    @Test func shownEpochsStayWhenARefreshFails() async {
        let client = FakeEarningsClient()
        client.epochRows = [Self.epoch(3), Self.epoch(4)]
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()
        client.epochsError = FetchError()
        await viewModel.refresh()

        #expect(viewModel.epochs.map(\.epoch) == [4, 3])
        #expect(viewModel.historyLoad == .loaded)
    }

    @Test func aFailedWalletReadIsNotNoWallet() async {
        let client = FakeEarningsClient()
        client.walletError = FetchError()
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.wallet == nil)
        #expect(viewModel.walletLoadFailed)

        // a read that answers "no wallet" is the real connect offer
        client.walletError = nil
        await viewModel.refresh()
        #expect(!viewModel.walletLoadFailed)
    }

    @Test func aFailedWalletReadWithACachedWalletShowsTheCachedWallet() async {
        let client = FakeEarningsClient()
        client.cached = SnWalletInfo(coldkeySs58: "5Cached", clientId: "client", setAtMillis: 1)
        client.walletError = FetchError()
        let viewModel = EarningsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.wallet?.coldkeySs58 == "5Cached")
        #expect(!viewModel.walletLoadFailed)
    }

    private static func epoch(_ epoch: Int64) -> AccountEpochInfo {
        AccountEpochInfo(epoch: epoch, startMillis: 0, endMillis: 0, points: 1, shareBps: 0)
    }

    // MARK: USDC payout wallet

    @Test func aFailedPayoutWalletReadIsReported() async {
        let client = FakeUsdcWalletsClient()
        client.walletsError = FetchError()
        let viewModel = UsdcWalletsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.payoutWallet == nil)
        #expect(viewModel.loadFailed)

        client.walletsError = nil
        await viewModel.refresh()
        #expect(!viewModel.loadFailed)
    }

    @Test func aFailedPayoutIdReadIsReported() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [UsdcWalletInfo(id: "w", chain: .sol, address: "a", hasSeekerToken: false)]
        client.payoutIdError = FetchError()
        let viewModel = UsdcWalletsViewModel(client: client)

        await viewModel.refresh()

        #expect(viewModel.loadFailed)
    }

    @Test func noPayoutWalletIsNotAFailure() async {
        let viewModel = UsdcWalletsViewModel(client: FakeUsdcWalletsClient())

        await viewModel.refresh()

        #expect(viewModel.payoutWallet == nil)
        #expect(!viewModel.loadFailed)
    }

    // MARK: SectionLoad

    @Test func sectionLoadPrefersDataThenFailureThenSettled() {
        #expect(SectionLoad.of(hasData: true, settled: true, failed: true) == .loaded)
        #expect(SectionLoad.of(hasData: false, settled: true, failed: true) == .failed)
        #expect(SectionLoad.of(hasData: false, settled: true, failed: false) == .loaded)
        #expect(SectionLoad.of(hasData: false, settled: false, failed: false) == .loading)
    }
}

/// A scripted EarningsClient: the reads the Earnings refresh makes answer from
/// the fields below or throw their error.
private final class FakeEarningsClient: EarningsClient {

    var cached: SnWalletInfo?
    var walletRow: SnWalletInfo?
    var walletError: Error?
    var epochRows: [AccountEpochInfo] = []
    var epochsError: Error?

    private struct Unsupported: Error {}

    func validateSs58(_ address: String) -> Bool { true }
    func shortSs58(_ address: String) -> String { address }
    func formatAlpha(rao: Int64) -> String { "\(rao)" }
    func formatShareBps(_ shareBps: Int64) -> String { "\(shareBps)" }

    func walletChallenge(address: String?) async throws -> String { throw Unsupported() }
    func validateWallet(_ address: String) async throws -> SnWalletValidation { throw Unsupported() }
    func cachedWallet() -> SnWalletInfo? { cached }

    func fetchWallet() async throws -> SnWalletInfo? {
        if let walletError {
            throw walletError
        }
        return walletRow
    }

    func connectWallet(coldkeySs58: String, signature: String, message: String) async throws -> SnWalletInfo {
        throw Unsupported()
    }

    func observeWallet(_ onChange: @escaping (SnWalletInfo?) -> Void) -> EarningsSubscription {
        EarningsSubscription {}
    }

    func syncChainSettings() async throws {}
    func gasKey() -> SnGasKeyInfo? { nil }
    func gasBalanceTao() async throws -> Double { 0 }
    func claims() async throws -> (claims: [SnEpochClaimInfo], totalClaimableRao: Int64) { ([], 0) }
    func claim(epochs: [Int64], onEvent: @escaping (SnClaimEvent) -> Void) {}

    func accountEpochs() async throws -> [AccountEpochInfo] {
        if let epochsError {
            throw epochsError
        }
        return epochRows
    }

    func head() async throws -> SnHeadInfo? { nil }
}
