//
//  ConnectBittensorWalletFlow.swift
//  URnetwork
//
//  Attaching a Bittensor coldkey to this device's provider client. The
//  coldkey is proven by an sr25519 signature from the ur.io wallet bridge over
//  a challenge with purpose "connect"; a pasted address still has to sign.
//  Every address is validated before it is sent anywhere: the local ss58
//  syntax check first, then the unauthenticated wallet check, which can warn
//  (no activity on chain yet) or block (banned).
//

import Foundation

@MainActor
final class ConnectBittensorWalletFlow: ObservableObject {

    enum Stage: Equatable {
        case chooser
        case manualEntry
        case checking
        case newWalletWarning
        case blocked
        case awaitingSignature
        case connecting
        case failed(String)
    }

    @Published var stage: Stage = .chooser
    @Published var manualAddress: String = ""
    @Published private(set) var address: String?

    private var signature: String?
    private var message: String?
    private var validated = false

    private let client: EarningsClient
    private let connect: (String, String, String) async throws -> SnWalletInfo

    /// opens the ur.io wallet bridge with the challenge to sign; set by the
    /// view that owns the wallet provider
    var openBridge: (String) -> Void = { _ in }
    var onConnected: (SnWalletInfo) -> Void = { _ in }

    init(
        client: EarningsClient,
        connect: @escaping (String, String, String) async throws -> SnWalletInfo
    ) {
        self.client = client
        self.connect = connect
    }

    func reset() {
        stage = .chooser
        manualAddress = ""
        address = nil
        signature = nil
        message = nil
        validated = false
    }

    /// Sign first: the wallet returns its address with the signature.
    func startBridge() async {
        address = nil
        signature = nil
        validated = false
        await openBridgeForSignature(address: nil)
    }

    func enterManually() {
        stage = .manualEntry
    }

    /// A pasted address: validate, then ask the wallet to sign for it.
    func submitManualAddress() async {
        let candidate = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard client.validateSs58(candidate) else {
            stage = .failed(String(localized: "That is not a valid Bittensor address."))
            return
        }
        address = candidate
        signature = nil
        switch await validate(candidate) {
        case .ok:
            await openBridgeForSignature(address: candidate)
        case .warn:
            stage = .newWalletWarning
        case .blocked:
            stage = .blocked
        case .error(let message):
            stage = .failed(message)
        }
    }

    /// After the new-wallet warning.
    func continueAnyway() async {
        guard let address else {
            reset()
            return
        }
        if let signature, let message {
            await finish(address: address, signature: signature, message: message)
        } else {
            await openBridgeForSignature(address: address)
        }
    }

    /// The bridge came back with the wallet's address and its signature over
    /// the challenge.
    func handleBridgeReturn(address returned: String, signature returnedSignature: String) async {
        guard stage == .awaitingSignature, let message else {
            return
        }
        if let expected = address, expected != returned {
            // a different wallet signed than the one pasted
            stage = .failed(String(localized: "There was an error connecting your wallet."))
            return
        }
        guard client.validateSs58(returned) else {
            stage = .failed(String(localized: "That is not a valid Bittensor address."))
            return
        }
        address = returned
        signature = returnedSignature
        if validated {
            await finish(address: returned, signature: returnedSignature, message: message)
            return
        }
        switch await validate(returned) {
        case .ok:
            await finish(address: returned, signature: returnedSignature, message: message)
        case .warn:
            stage = .newWalletWarning
        case .blocked:
            stage = .blocked
        case .error(let errorMessage):
            stage = .failed(errorMessage)
        }
    }

    func handleBridgeError(_ error: Error) {
        if stage == .awaitingSignature {
            stage = .failed(String(localized: "There was an error connecting your wallet."))
        }
    }

    func retry() async {
        if let address {
            if validated {
                await openBridgeForSignature(address: address)
            } else {
                manualAddress = address
                await submitManualAddress()
            }
        } else {
            await startBridge()
        }
    }

    private enum Validation {
        case ok
        case warn
        case blocked
        case error(String)
    }

    private func validate(_ candidate: String) async -> Validation {
        stage = .checking
        do {
            let result = try await client.validateWallet(candidate)
            if !result.validSyntax {
                return .error(String(localized: "That is not a valid Bittensor address."))
            }
            if result.banned {
                return .blocked
            }
            validated = true
            return result.existsOnChain ? .ok : .warn
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func openBridgeForSignature(address: String?) async {
        do {
            let challenge = try await client.walletChallenge(address: address)
            message = challenge
            stage = .awaitingSignature
            openBridge(challenge)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func finish(address: String, signature: String, message: String) async {
        stage = .connecting
        do {
            let wallet = try await connect(address, signature, message)
            onConnected(wallet)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}
