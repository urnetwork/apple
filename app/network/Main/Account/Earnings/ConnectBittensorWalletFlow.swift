//
//  ConnectBittensorWalletFlow.swift
//  URnetwork
//
//  Attaching a Bittensor coldkey to this device's provider client. The
//  coldkey is proven by an sr25519 signature over a challenge with purpose
//  "connect", produced through the SDK's wallet-connect session
//  (BittensorWalletConnector): Talisman on macOS signs through the ur.io
//  bridge in the browser and returns its address; a manual wallet (iOS, and
//  TAO.com everywhere) first takes the address, then the pasted signature
//  over a challenge bound to it.
//  Every address is validated before it is sent anywhere: the local ss58
//  syntax check first, then the unauthenticated wallet check, which can warn
//  (no activity on chain yet) or block (banned).
//

import Foundation
import URnetworkSdk

@MainActor
final class ConnectBittensorWalletFlow: ObservableObject {

    enum Stage: Equatable {
        case chooser
        /// a manual wallet: the address first
        case manualEntry
        case checking
        case newWalletWarning
        case blocked
        /// the connector is up (manual form or browser hand-off)
        case signing
        case connecting
        case failed(String)
    }

    @Published var stage: Stage = .chooser
    @Published var manualAddress: String = ""
    @Published private(set) var address: String?
    @Published private(set) var walletId: String?

    private var signature: String?
    private var message: String?
    private var validated = false

    private let client: EarningsClient
    private let connect: (String, String, String) async throws -> SnWalletInfo
    private let platform: String
    let connector: BittensorWalletConnector

    var onConnected: (SnWalletInfo) -> Void = { _ in }

    init(
        client: EarningsClient,
        platform: String = BittensorWallet.platform,
        connector: BittensorWalletConnector? = nil,
        connect: @escaping (String, String, String) async throws -> SnWalletInfo
    ) {
        self.client = client
        self.connect = connect
        self.platform = platform
        self.connector = connector ?? BittensorWalletConnector(
            platform: platform,
            fetchChallenge: { args in
                try await client.walletChallenge(args)
            }
        )
        self.connector.onProof = { [weak self] proof in
            await self?.handleProof(proof)
        }
    }

    func reset() {
        connector.cancel()
        stage = .chooser
        manualAddress = ""
        address = nil
        walletId = nil
        signature = nil
        message = nil
        validated = false
    }

    /// A wallet from the chooser. A browser-bridge wallet signs first and
    /// returns its address; a manual one takes the address first.
    func chooseWallet(_ walletId: String) async {
        self.walletId = walletId
        address = nil
        signature = nil
        message = nil
        validated = false
        if BittensorWallet.transport(walletId, platform: platform) == SdkBittensorWalletTransportBrowserBridge {
            await startSigning(address: nil)
        } else {
            stage = .manualEntry
        }
    }

    /// A typed address: validate, then sign for it.
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
            await startSigning(address: candidate)
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
            await startSigning(address: address)
        }
    }

    /// The session accepted a signature (the SDK has checked the challenge,
    /// the purpose, the ss58 address, a typed address match and the
    /// signature shape).
    func handleProof(_ proof: BittensorWalletProofInfo) async {
        guard stage == .signing else {
            return
        }
        address = proof.address
        signature = proof.signature
        message = proof.message
        if validated {
            await finish(address: proof.address, signature: proof.signature, message: proof.message)
            return
        }
        switch await validate(proof.address) {
        case .ok:
            await finish(address: proof.address, signature: proof.signature, message: proof.message)
        case .warn:
            stage = .newWalletWarning
        case .blocked:
            stage = .blocked
        case .error(let errorMessage):
            stage = .failed(errorMessage)
        }
    }

    func retry() async {
        guard let walletId else {
            reset()
            return
        }
        if let address, validated {
            await startSigning(address: address)
        } else {
            await chooseWallet(walletId)
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

    private func startSigning(address: String?) async {
        guard let walletId else {
            reset()
            return
        }
        stage = .signing
        await connector.choose(
            walletId: walletId,
            purpose: SdkBittensorWalletPurposeConnect,
            expectedAddress: address ?? ""
        )
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
