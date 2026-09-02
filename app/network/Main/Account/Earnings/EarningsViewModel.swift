//
//  EarningsViewModel.swift
//  URnetwork
//
//  State of the points-first Earnings screen. Points come from the account
//  points store; this holds the subnet layer, which only carries data once a
//  Bittensor coldkey is attached: the wallet, the epoch history rows, the
//  vault claims, the gas key balance and the Top 200 head status.
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

    @Published private(set) var wallet: SnWalletInfo?
    @Published private(set) var epochs: [AccountEpochInfo] = []
    @Published private(set) var claims: [SnEpochClaimInfo] = []
    @Published private(set) var totalClaimableRao: Int64 = 0
    @Published private(set) var gasKey: SnGasKeyInfo?
    @Published private(set) var gasTao: Double?
    @Published private(set) var head: SnHeadInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var errorMessage: String?

    @Published private(set) var claimProgress: [Int64: ClaimRowState] = [:]
    @Published private(set) var isClaiming = false

    let client: EarningsClient
    private var walletSubscription: EarningsSubscription?
    private var chainSettingsSynced = false

    /// a rough per-claim gas reserve in TAO; the SDK reports the real
    /// shortfall as a failed claim
    static let gasTaoPerClaim = 0.005

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

    var showsTop200Tile: Bool {
        guard let head else { return false }
        return head.eligible || head.bound
    }

    func refresh() async {
        if isLoading {
            return
        }
        isLoading = true
        errorMessage = nil

        async let walletTask: SnWalletInfo?? = try? client.fetchWallet()
        async let epochsTask: [AccountEpochInfo]? = try? client.accountEpochs()
        async let headTask: SnHeadInfo?? = try? client.head()

        let (walletResult, epochsResult, headResult) = await (walletTask, epochsTask, headTask)
        if let walletResult {
            wallet = walletResult
        } else {
            wallet = client.cachedWallet()
        }
        if let epochsResult {
            epochs = epochsResult.sorted { $0.epoch > $1.epoch }
        }
        if let headResult {
            head = headResult
        }

        await refreshSubnet()

        loadedOnce = true
        isLoading = false
    }

    /// The layer that only exists with a wallet: gas key, balance, claims.
    func refreshSubnet() async {
        guard hasWallet else {
            claims = []
            totalClaimableRao = 0
            gasTao = nil
            return
        }
        if !chainSettingsSynced {
            // the vault and coordinator addresses come from the server once;
            // retried on the next refresh if it fails
            chainSettingsSynced = (try? await client.syncChainSettings()) != nil
        }
        gasKey = client.gasKey()
        async let balanceTask: Double? = try? client.gasBalanceTao()
        async let claimsTask: (claims: [SnEpochClaimInfo], totalClaimableRao: Int64)? = try? client.claims()
        let (balance, claimsResult) = await (balanceTask, claimsTask)
        gasTao = balance
        if let claimsResult {
            claims = claimsResult.claims.sorted { $0.epoch > $1.epoch }
            totalClaimableRao = claimsResult.totalClaimableRao
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
}
