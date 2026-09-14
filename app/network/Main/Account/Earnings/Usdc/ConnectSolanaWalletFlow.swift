//
//  ConnectSolanaWalletFlow.swift
//  URnetwork
//
//  Linking the Solana wallet USDC payouts go to until the migration to
//  Bittensor is complete. Phantom or Solflare (the apps on iOS, their browser
//  extensions through the ur.io bridge on macOS) return the wallet's public
//  key through the encrypted connect round trip; nothing is signed. A pasted
//  address is checked on the Solana chain first. Linking makes the wallet the
//  payout wallet: the server does it when the network has none, the flow
//  selects it otherwise.
//

import Combine
import Foundation

@MainActor
final class ConnectSolanaWalletFlow: ObservableObject {

    enum WalletApp: Equatable {
        case phantom
        case solflare
    }

    enum Stage: Equatable {
        case chooser
        case awaitingWallet(WalletApp)
        case manualEntry
        case connecting
        case failed(String)
    }

    private enum Attempt {
        case wallet(WalletApp)
        case manual
    }

    @Published var stage: Stage = .chooser
    @Published var manualAddress: String = ""
    @Published private(set) var manualValidation: ValidationState = .notChecked
    /// "Checking address…", "That is not a valid Solana address.", the error
    /// of a check that failed, or nil
    @Published private(set) var manualSupportingText: String?

    /// hands off to the wallet; set by the view that owns the wallet provider.
    /// Returns whether the hand-off started.
    var openWallet: (WalletApp) -> Bool = { _ in false }
    /// called with the linked wallet's id
    var onConnected: (String) -> Void = { _ in }

    /// the address check in flight, if any
    private(set) var validationTask: Task<Void, Never>?

    private let client: UsdcWalletsClient
    private let validationDebounce: Duration
    private var lastAttempt: Attempt?
    private var cancellables = Set<AnyCancellable>()

    init(client: UsdcWalletsClient, validationDebounce: Duration = .milliseconds(300)) {
        self.client = client
        self.validationDebounce = validationDebounce
        // delivered inside the address's willSet: use the emitted value, never
        // read manualAddress here
        $manualAddress
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] address in
                self?.scheduleValidation(of: address)
            }
            .store(in: &cancellables)
    }

    private var trimmedManualAddress: String {
        manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reset() {
        validationTask?.cancel()
        validationTask = nil
        lastAttempt = nil
        stage = .chooser
        manualAddress = ""
        manualValidation = .notChecked
        manualSupportingText = nil
    }

    /// Hands off to the wallet app (iOS) or the ur.io browser bridge (macOS).
    /// When the hand-off does not start, the stage stays on the chooser and
    /// the view says the wallet could not be opened.
    @discardableResult
    func start(_ app: WalletApp) -> Bool {
        lastAttempt = .wallet(app)
        guard openWallet(app) else {
            stage = .chooser
            return false
        }
        stage = .awaitingWallet(app)
        return true
    }

    func enterManually() {
        stage = .manualEntry
    }

    /// Links the pasted address once the Solana check has passed.
    func submitManualAddress() async {
        guard manualValidation == .valid, stage != .connecting else {
            return
        }
        lastAttempt = .manual
        await link(trimmedManualAddress)
    }

    /// The wallet came back through urnetwork://phantom-connect or
    /// urnetwork://solflare-connect with its public key. Taken while the
    /// hand-off is awaited and also after it reported an error: the ur.io
    /// bridge's Try again returns a key for the same hand-off after its error,
    /// and only this hand-off's key pair decrypts the envelope.
    func handleWalletReturn(publicKey: String, provider: ConnectedWalletProvider) async {
        guard case .wallet? = lastAttempt else {
            return
        }
        switch stage {
        case .awaitingWallet, .failed:
            break
        case .chooser, .manualEntry, .connecting:
            return
        }
        switch provider {
        case .phantom, .solflare:
            await link(publicKey)
        case .bittensor:
            return
        }
    }

    /// The wallet came back with an error: rejected, or an envelope that did
    /// not decrypt.
    func handleWalletError(_ error: Error) {
        guard case .awaitingWallet = stage else {
            return
        }
        stage = .failed(Self.errorMessage(for: error))
    }

    /// Repeats the last attempt: re-opens the same wallet, or returns to the
    /// manual entry with the address kept.
    func retry() async {
        switch lastAttempt {
        case .wallet(let app):
            start(app)
        case .manual:
            stage = .manualEntry
        case nil:
            stage = .chooser
        }
    }

    private func link(_ address: String) async {
        stage = .connecting
        do {
            let walletId = try await client.addSolanaWallet(address: address)
            // the server selects the new wallet only when the network has no
            // payout wallet; selecting it again is harmless, so a payout read
            // that fails selects it too
            let payoutWalletId = try? await client.payoutWalletId()
            if payoutWalletId != walletId {
                try await client.setPayoutWallet(id: walletId)
            }
            onConnected(walletId)
        } catch {
            stage = .failed(Self.errorMessage(for: error))
        }
    }

    private func scheduleValidation(of address: String) {
        validationTask?.cancel()
        let candidate = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            validationTask = nil
            manualValidation = .notChecked
            manualSupportingText = nil
            return
        }
        manualValidation = .validating
        manualSupportingText = String(localized: "Checking address…")
        let client = client
        let debounce = validationDebounce
        validationTask = Task { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else {
                return
            }
            let outcome: Result<Bool, Error>
            do {
                outcome = .success(try await client.validateSolanaAddress(candidate))
            } catch {
                outcome = .failure(error)
            }
            // a newer address replaced this one while it was being checked
            guard let self, !Task.isCancelled, self.trimmedManualAddress == candidate else {
                return
            }
            switch outcome {
            case .success(true):
                self.manualValidation = .valid
                self.manualSupportingText = nil
            case .success(false):
                self.manualValidation = .invalid
                self.manualSupportingText = String(localized: "That is not a valid Solana address.")
            case .failure(let error):
                // the check itself failed: the address is not known to be
                // invalid, and it is not submittable either
                self.manualValidation = .notChecked
                self.manualSupportingText = Self.errorMessage(for: error)
            }
        }
    }

    /// "There was an error connecting your wallet: <detail>", or the sentence
    /// alone when the error carries no detail.
    static func errorMessage(for error: Error) -> String {
        let detail = errorDetail(error)
        if detail.isEmpty {
            return String(localized: "There was an error connecting your wallet.")
        }
        return String(localized: "There was an error connecting your wallet: \(detail)")
    }

    /// what the wallet provider puts before a wallet's own errorMessage
    private static let walletConnectErrorPrefix = "Wallet connect error: "

    private static func errorDetail(_ error: Error) -> String {
        let description: String
        if let deepLinkError = error as? WalletDeepLinkError {
            if case .walletError(let message) = deepLinkError {
                description = message
            } else {
                description = ""
            }
        } else {
            description = error.localizedDescription
        }
        let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.hasPrefix(walletConnectErrorPrefix) {
            return String(detail.dropFirst(walletConnectErrorPrefix.count))
        }
        return detail
    }
}
