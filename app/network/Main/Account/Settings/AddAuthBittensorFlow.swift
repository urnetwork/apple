//
//  AddAuthBittensorFlow.swift
//  URnetwork
//
//  The add sign-in method sheet's Bittensor wallet: the shared wallet
//  chooser and SDK session (BittensorWalletConnector) under the "add"
//  purpose, then AddAuth with the proof on the network the session is on.
//
//  The flow only ever calls AddAuth: it never signs in, never creates a
//  network and never touches the session's jwt, so adding a wallet cannot
//  sign in as it. A bridge hand-back for a sign-in (login, create) or the
//  payout wallet (connect) is another flow's: the SDK session refuses it by
//  purpose and the connector ignores it, and the login screen's session
//  refuses an "add" hand-back the same way.
//

import Foundation
import URnetworkSdk

@MainActor
final class AddAuthBittensorFlow: ObservableObject {

    let connector: BittensorWalletConnector

    @Published private(set) var isAdding: Bool = false
    @Published private(set) var addError: String?

    /// Called once AddAuth added the wallet.
    var onAdded: () async -> Void = {}

    private let addAuth: (SdkAddAuthArgs) async throws -> Void

    init(
        connector: BittensorWalletConnector,
        addAuth: @escaping (SdkAddAuthArgs) async throws -> Void
    ) {
        self.connector = connector
        self.addAuth = addAuth
        connector.onProof = { [weak self] proof in
            await self?.add(proof)
        }
    }

    convenience init(api: UrApiServiceProtocol) {
        self.init(
            connector: BittensorWalletConnector(fetchChallenge: { args in
                try await api.authWalletChallenge(args)
            }),
            addAuth: { args in
                _ = try await api.addAuth(args)
            }
        )
    }

    /// A wallet was picked in the chooser: a fresh challenge for adding.
    func choose(walletId: String) async {
        addError = nil
        await connector.choose(walletId: walletId, purpose: SdkBittensorWalletPurposeAdd)
    }

    /// Routes a url to the session; true when it was this flow's redirect
    /// link while a session is open.
    func handleOpenUrl(_ url: URL) async -> Bool {
        guard connector.isBridgeReturn(url) else {
            return false
        }
        await connector.handleBridgeReturn(url)
        return true
    }

    func cancel() {
        connector.cancel()
        addError = nil
    }

    private func add(_ proof: BittensorWalletProofInfo) async {
        // only the sheet's own proof is added
        guard let args = addAuthBittensorArgs(proof) else {
            return
        }
        isAdding = true
        addError = nil
        do {
            try await addAuth(args)
            isAdding = false
            await onAdded()
        } catch {
            isAdding = false
            addError = Self.failureText(error, walletId: proof.walletId, platform: connector.platform)
        }
    }

    /// What a refused add shows: a signature pasted from `walletId` that is
    /// not from the entered address (the server's signature_mismatch), in that
    /// wallet's words; a browser-bridge signature and every other refusal show
    /// the error as before.
    static func failureText(_ error: Error, walletId: String, platform: String) -> String {
        if error is WalletSignatureMismatchError,
           let text = BittensorWallet.signatureMismatchText(walletId: walletId, platform: platform) {
            return text
        }
        return error.localizedDescription
    }
}
