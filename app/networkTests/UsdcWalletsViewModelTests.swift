//
//  UsdcWalletsViewModelTests.swift
//  networkTests
//
//  The legacy USDC payout wallet state behind the Solana wallet card: which
//  account wallets count as USDC wallets, which one is the payout wallet, how
//  much USDC is waiting and when the waiting line shows, and removal.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

@MainActor
struct UsdcWalletsViewModelTests {

    private static func wallet(_ id: String, chain: UsdcChain = .sol) -> UsdcWalletInfo {
        UsdcWalletInfo(id: id, chain: chain, address: "address-\(id)", hasSeekerToken: false)
    }

    private static func payment(
        _ id: String,
        nanoCents: Int64,
        completed: Bool = false,
        canceled: Bool = false
    ) -> UsdcPaymentInfo {
        UsdcPaymentInfo(
            id: id,
            walletId: nil,
            payoutNanoCents: nanoCents,
            tokenAmount: 0,
            completed: completed,
            canceled: canceled,
            completeTimeMillis: nil
        )
    }

    private static func sdkWallet(
        blockchain: String,
        address: String,
        active: Bool = true,
        circleWalletId: String = ""
    ) -> SdkAccountWallet {
        let wallet = SdkAccountWallet()
        wallet.walletId = SdkNewId()
        wallet.blockchain = blockchain
        wallet.walletAddress = address
        wallet.active = active
        wallet.circleWalletId = circleWalletId
        return wallet
    }

    @Test func refreshKeepsOnlyUsdcWallets() async throws {
        // the sdk mapping drops TAO, inactive and Circle rows
        let list = try #require(SdkAccountWalletsList())
        list.add(Self.sdkWallet(blockchain: "SOL", address: "solana"))
        list.add(Self.sdkWallet(blockchain: "TAO", address: "bittensor"))
        list.add(Self.sdkWallet(blockchain: "SOL", address: "inactive", active: false))
        list.add(Self.sdkWallet(blockchain: "SOL", address: "circle", circleWalletId: "circle-wallet"))
        list.add(Self.sdkWallet(blockchain: "MATIC", address: "polygon"))

        let mapped = UsdcWalletsSdkClient.usdcWallets(from: list)
        #expect(mapped.map(\.address) == ["solana", "polygon"])
        #expect(mapped.map(\.chain) == [.sol, .matic])
        #expect(mapped.allSatisfy { !$0.id.isEmpty })
        #expect(UsdcWalletsSdkClient.usdcWallets(from: nil).isEmpty)

        // the view model keeps the client's order
        let client = FakeUsdcWalletsClient()
        client.walletRows = mapped
        let viewModel = UsdcWalletsViewModel(client: client)
        #expect(!viewModel.loadedOnce)
        await viewModel.refresh()
        #expect(viewModel.loadedOnce)
        #expect(viewModel.wallets == mapped)
    }

    @Test func payoutWalletIsTheSelectedUsdcWallet() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("first"), Self.wallet("second", chain: .matic)]
        client.payoutId = "second"
        let viewModel = UsdcWalletsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.payoutWallet == Self.wallet("second", chain: .matic))

        // a payout wallet id that is not an active USDC wallet
        client.payoutId = "not-a-usdc-wallet"
        await viewModel.refresh()
        #expect(viewModel.payoutWalletId == "not-a-usdc-wallet")
        #expect(viewModel.payoutWallet == nil)

        // the network has no payout wallet
        client.payoutId = nil
        await viewModel.refresh()
        #expect(viewModel.payoutWalletId == nil)
        #expect(viewModel.payoutWallet == nil)
    }

    @Test func pendingUsdSumsUncompletedPayments() async throws {
        let list = try #require(SdkAccountPaymentsList())
        let rows: [(payout: Int64, completed: Bool, canceled: Bool)] = [
            (3_000_000_000, false, false),
            (870_000_000, false, false),
            (5_000_000_000, true, false),
            (7_000_000_000, false, true),
        ]
        for row in rows {
            let payment = SdkAccountPayment()
            payment.payout = row.payout
            payment.completed = row.completed
            payment.canceled = row.canceled
            list.add(payment)
        }
        let mapped = UsdcWalletsSdkClient.payments(from: list)
        #expect(mapped.map(\.payoutNanoCents) == rows.map(\.payout))
        #expect(mapped.map(\.isPending) == [true, true, false, false])
        #expect(Set(mapped.map(\.id)).count == rows.count)

        let client = FakeUsdcWalletsClient()
        client.paymentRows = mapped
        let viewModel = UsdcWalletsViewModel(client: client)
        await viewModel.refresh()
        #expect(viewModel.pendingUsdNanoCents == 3_870_000_000)
        #expect(viewModel.pendingUsd == "3.87")

        client.paymentRows = [Self.payment("paid", nanoCents: 1_000_000_000, completed: true)]
        await viewModel.refresh()
        #expect(viewModel.pendingUsdNanoCents == 0)
        #expect(viewModel.pendingUsd == nil)
    }

    @Test func thePendingLineShowsOnlyWithoutAPayoutWallet() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("solana")]
        client.paymentRows = [Self.payment("waiting", nanoCents: 3_870_000_000)]
        let viewModel = UsdcWalletsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.payoutWallet == nil)
        #expect(viewModel.showsPendingLine)

        // linked: the amount moves to the Solana wallet card
        client.payoutId = "solana"
        await viewModel.refresh()
        #expect(viewModel.payoutWallet == Self.wallet("solana"))
        #expect(!viewModel.showsPendingLine)
        #expect(viewModel.pendingUsd == "3.87")

        // nothing waiting
        client.payoutId = nil
        client.paymentRows = []
        await viewModel.refresh()
        #expect(!viewModel.showsPendingLine)
    }

    @Test func aFailedFetchKeepsTheLastState() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("solana")]
        client.payoutId = "solana"
        client.paymentRows = [Self.payment("waiting", nanoCents: 1_000_000_000)]
        let viewModel = UsdcWalletsViewModel(client: client)
        await viewModel.refresh()

        client.walletRows = []
        client.payoutId = nil
        client.paymentRows = []
        client.walletsError = UsdcWalletsClientError.message("offline")
        client.payoutIdError = UsdcWalletsClientError.message("offline")
        client.paymentsError = UsdcWalletsClientError.message("offline")
        await viewModel.refresh()
        #expect(viewModel.wallets == [Self.wallet("solana")])
        #expect(viewModel.payoutWalletId == "solana")
        #expect(viewModel.pendingUsd == "1.00")
        #expect(!viewModel.isLoading)
    }

    @Test func removeWalletRefreshesAndClearsTheQueue() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("solana")]
        client.payoutId = "solana"
        let viewModel = UsdcWalletsViewModel(client: client)
        await viewModel.refresh()
        viewModel.walletQueuedForRemoval = Self.wallet("solana")

        let result = await viewModel.removeWallet("solana")
        guard case .success = result else {
            Issue.record("remove failed: \(result)")
            return
        }
        #expect(client.calls.contains(.remove("solana")))
        #expect(client.calls.filter { $0 == .wallets }.count == 2)
        #expect(viewModel.walletQueuedForRemoval == nil)
        #expect(viewModel.wallets.isEmpty)
        #expect(viewModel.payoutWallet == nil)
        #expect(!viewModel.isRemoving)
    }

    @Test func aFailedRemoveReturnsTheErrorAndLeavesTheState() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("solana")]
        client.payoutId = "solana"
        let viewModel = UsdcWalletsViewModel(client: client)
        await viewModel.refresh()
        viewModel.walletQueuedForRemoval = Self.wallet("solana")
        client.removeError = UsdcWalletsClientError.message("wallet not found")
        let callsBefore = client.calls.count

        let result = await viewModel.removeWallet("solana")
        guard case .failure(let error) = result else {
            Issue.record("remove unexpectedly succeeded")
            return
        }
        #expect(error as? UsdcWalletsClientError == .message("wallet not found"))
        // no refresh after a failure
        #expect(client.calls.count == callsBefore + 1)
        #expect(viewModel.wallets == [Self.wallet("solana")])
        #expect(viewModel.payoutWallet == Self.wallet("solana"))
        #expect(viewModel.walletQueuedForRemoval == Self.wallet("solana"))
        #expect(!viewModel.isRemoving)
    }

    @Test func usdFormatsNanoCentsWithTwoDecimals() {
        #expect(UsdcFormat.usd(nanoCents: 3_870_000_000) == "3.87")
        #expect(UsdcFormat.usd(nanoCents: 0) == "0.00")
        #expect(UsdcFormat.usd(nanoCents: 12_345_678_900) == "12.35")
    }

    // MARK: refresh order and the waiting line

    @Test func anOlderRefreshNeverOverwritesANewerOne() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("solana")]
        client.payoutId = "solana"
        var release: CheckedContinuation<Void, Never>?
        var holdNextPayments = true
        client.beforePaymentsReturn = {
            guard holdNextPayments else {
                return
            }
            holdNextPayments = false
            await withCheckedContinuation { continuation in
                release = continuation
            }
        }
        let viewModel = UsdcWalletsViewModel(client: client)

        // the older round has read the linked wallet and waits for the payments
        let older = Task {
            await viewModel.refresh()
        }
        for _ in 0..<1000 where release == nil || !client.calls.contains(.wallets) || !client.calls.contains(.payoutWalletId) {
            await Task.yield()
        }
        #expect(release != nil)

        // the wallet is removed meanwhile; the newer round reads that and finishes first
        client.walletRows = []
        client.payoutId = nil
        await viewModel.refresh()
        #expect(viewModel.payoutWallet == nil)

        release?.resume()
        await older.value
        #expect(viewModel.wallets.isEmpty)
        #expect(viewModel.payoutWalletId == nil)
        #expect(!viewModel.isLoading)
    }

    @Test func anAmountThatRoundsToZeroIsNotWaiting() async {
        let client = FakeUsdcWalletsClient()
        client.paymentRows = [Self.payment("dust", nanoCents: 4_999_999)]
        let viewModel = UsdcWalletsViewModel(client: client)

        await viewModel.refresh()
        #expect(viewModel.pendingUsd == nil)
        #expect(!viewModel.showsPendingLine)

        client.paymentRows = [Self.payment("half a cent", nanoCents: 5_000_000)]
        await viewModel.refresh()
        #expect(viewModel.pendingUsd == "0.01")
        #expect(viewModel.showsPendingLine)
    }

    @Test func aFailedFirstReadDoesNotClaimAMissingWallet() async {
        let client = FakeUsdcWalletsClient()
        client.walletRows = [Self.wallet("solana")]
        client.payoutId = "solana"
        client.paymentRows = [Self.payment("waiting", nanoCents: 3_870_000_000)]
        client.payoutIdError = UsdcWalletsClientError.message("offline")
        let viewModel = UsdcWalletsViewModel(client: client)

        // the payout wallet could not be read: no card, and no claim that none is connected
        await viewModel.refresh()
        #expect(viewModel.payoutWallet == nil)
        #expect(!viewModel.showsPendingLine)

        // nor when the wallets could not be read
        let walletsClient = FakeUsdcWalletsClient()
        walletsClient.payoutId = "solana"
        walletsClient.paymentRows = [Self.payment("waiting", nanoCents: 3_870_000_000)]
        walletsClient.walletsError = UsdcWalletsClientError.message("offline")
        let walletsViewModel = UsdcWalletsViewModel(client: walletsClient)
        await walletsViewModel.refresh()
        #expect(!walletsViewModel.showsPendingLine)

        // once read, the card shows the wallet
        client.payoutIdError = nil
        await viewModel.refresh()
        #expect(viewModel.payoutWallet == Self.wallet("solana"))
        #expect(!viewModel.showsPendingLine)
    }
}
