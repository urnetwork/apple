//
//  UsdcWalletsViewModel.swift
//  URnetwork
//
//  State of the legacy USDC payout wallet on the Earnings screen: the
//  account's USDC wallets, the payout wallet among them and the USDC that is
//  still waiting to be paid out. Only the payout wallet is shown.
//

import Foundation

@MainActor
final class UsdcWalletsViewModel: ObservableObject {

    @Published private(set) var wallets: [UsdcWalletInfo] = []
    @Published private(set) var payoutWalletId: String?
    @Published private(set) var payments: [UsdcPaymentInfo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var isRemoving = false
    /// the wallet the remove confirmation asks about
    @Published var walletQueuedForRemoval: UsdcWalletInfo?

    let client: UsdcWalletsClient

    private var refreshGeneration = 0
    private var refreshesInFlight = 0

    init(client: UsdcWalletsClient) {
        self.client = client
    }

    /// The USDC wallet payouts go to; nil when the payout wallet is not an
    /// active USDC wallet.
    var payoutWallet: UsdcWalletInfo? {
        guard let payoutWalletId else {
            return nil
        }
        return wallets.first { $0.id == payoutWalletId }
    }

    /// the payouts that are neither completed nor canceled
    var pendingUsdNanoCents: Int64 {
        payments.filter(\.isPending).reduce(0) { $0 + $1.payoutNanoCents }
    }

    /// "3.87", or nil when nothing is waiting
    var pendingUsd: String? {
        let pending = pendingUsdNanoCents
        guard pending > 0 else {
            return nil
        }
        return UsdcFormat.usd(nanoCents: pending)
    }

    /// USDC is waiting and there is no Solana payout wallet to send it to.
    var showsPendingLine: Bool {
        pendingUsdNanoCents > 0 && payoutWallet == nil
    }

    /// The wallets, the payout wallet and the payments in one round. A fetch
    /// that fails keeps its last state.
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshesInFlight += 1
        isLoading = true

        let client = client
        async let walletsTask = attempt { try await client.wallets() }
        async let payoutTask = attempt { try await client.payoutWalletId() }
        async let paymentsTask = attempt { try await client.payments() }
        let (walletsResult, payoutResult, paymentsResult) = await (walletsTask, payoutTask, paymentsTask)

        refreshesInFlight -= 1
        isLoading = refreshesInFlight > 0
        // a newer round started while this one was in flight; its results win
        guard generation == refreshGeneration else {
            return
        }
        if let walletsResult {
            wallets = walletsResult
        }
        if let payoutResult {
            payoutWalletId = payoutResult
        }
        if let paymentsResult {
            payments = paymentsResult
        }
        loadedOnce = true
    }

    /// Removes the wallet, then refreshes. The server drops the payout wallet
    /// with it, so USDC payouts are held until another wallet is connected.
    func removeWallet(_ id: String) async -> Result<Void, Error> {
        guard !isRemoving else {
            return .failure(UsdcWalletsClientError.message("A wallet is already being removed"))
        }
        isRemoving = true
        do {
            try await client.removeWallet(id: id)
        } catch {
            isRemoving = false
            return .failure(error)
        }
        walletQueuedForRemoval = nil
        await refresh()
        isRemoving = false
        return .success(())
    }
}

/// The value, or nil when the fetch threw, so an optional result (no payout
/// wallet) stays distinguishable from a failure.
private func attempt<T>(_ operation: () async throws -> T) async -> T? {
    do {
        return try await operation()
    } catch {
        return nil
    }
}
