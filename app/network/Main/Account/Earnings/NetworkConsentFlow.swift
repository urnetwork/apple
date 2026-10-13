//
//  NetworkConsentFlow.swift
//  URnetwork
//
//  The network payout consent: one sr25519 signature by a Bittensor coldkey,
//  asked for by the network's owner, pays every provider client of the
//  network to that coldkey, in settlement v1 and v2. Without one the
//  network's earnings are not paid. Signing takes the coldkey address
//  first, since the server's message names it. The wallet then signs that
//  message as issued, through the shared wallet connector under the
//  "consent" purpose (the ur.io bridge in the browser, or the manual form),
//  and the app sends back that message and nothing else. A consent starts
//  next epoch, so a first one and a change of wallet both take effect from
//  the next epoch.
//

import Foundation
import URnetworkSdk

/// Why signing a consent stopped, each in its own words.
enum NetworkConsentFailure: Equatable {
    /// the challenge expired (300 s) before its signature reached the server
    case expired
    /// the signature does not verify for the coldkey (signature_mismatch)
    case signatureMismatch
    /// the session is not the network owner's (network_owner_only)
    case ownerOnly
    /// any other error, as the SDK or the wallet wrote it
    case message(String)

    /// The failure an error reads as: a refused signature keeps its own
    /// case, the SDK's code (SnErrorCode*, the start of its "code: message"
    /// errors) picks the consent's words, and any other error shows as it
    /// was written.
    static func of(_ error: Error) -> NetworkConsentFailure {
        if case EarningsClientError.signatureMismatch = error {
            return .signatureMismatch
        }
        let message = error.localizedDescription
        switch SnLedgerClaimFailure.code(of: message) {
        case SdkSnErrorCodeNetworkOwnerOnly:
            return .ownerOnly
        case SdkSnErrorCodeChallengeExpired:
            return .expired
        default:
            return .message(message)
        }
    }

    var text: String {
        switch self {
        case .expired:
            return String(localized: "The request expired. Try again.")
        case .signatureMismatch:
            return String(localized: "The signature didn't match this wallet. Try again.")
        case .ownerOnly:
            return String(localized: "Only the network owner can choose the payout wallet.")
        case .message(let message):
            return message
        }
    }
}

@MainActor
final class NetworkConsentFlow: ObservableObject {

    /// The network's consent, from the latest status read.
    enum Status: Equatable {
        /// nothing read yet
        case loading
        /// the latest read failed: unknown, which is not "no consent"
        case unavailable
        /// no consent is in force or starting: earnings are not paid
        case noConsent
        /// earnings are paid to the coldkey, now or from the next epoch
        case active(coldkeySs58: String)
    }

    /// The signing sheet.
    enum Stage: Equatable {
        case chooser
        /// the coldkey address, which the server's message names
        case addressEntry
        /// asking the server for the message
        case requestingChallenge
        /// the wallet has the message: the connector's browser hand-off or
        /// manual form
        case signing
        /// the signature is on its way to the server
        case submitting
        case failed(NetworkConsentFailure)
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var stage: Stage = .chooser
    @Published var address: String = ""
    @Published private(set) var addressError: String?
    @Published private(set) var walletId: String?

    let connector: BittensorWalletConnector
    private let client: NetworkConsentClient
    private let now: () -> Int64
    /// the challenge with the wallet, while it signs
    private var challenge: SdkSnNetworkConsentChallengeResult?
    /// counts the challenge requests: a reset or a newer request makes an
    /// answer in flight stale
    private var requests = 0

    /// the consent was stored and its status read again
    var onSigned: () -> Void = {}

    init(
        client: NetworkConsentClient,
        platform: String = BittensorWallet.platform,
        connector: BittensorWalletConnector? = nil,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.client = client
        self.now = now
        self.connector = connector ?? BittensorWalletConnector(
            platform: platform,
            // the consent's challenge comes from SnNetworkConsentChallenge;
            // this connector never asks for a sign-in challenge
            fetchChallenge: { _ in
                throw BittensorWalletConnectorError.unsupported
            },
            now: now
        )
        self.connector.onProof = { [weak self] proof in
            await self?.handleProof(proof)
        }
        self.connector.onRefusal = { [weak self] code in
            self?.handleRefusal(code)
        }
    }

    /// The server's message is on its way to the wallet, or with it: the
    /// sheet waits for the signature.
    var awaitingSignature: Bool {
        switch stage {
        case .requestingChallenge:
            return true
        case .signing:
            switch connector.stage {
            case .awaitingBrowser, .manualSignature:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    /// Reads the network's consent. The latest read decides: a failed one is
    /// unavailable even after a good one.
    func refreshStatus() async {
        do {
            let consent = try await client.status()
            status = consent.active ? .active(coldkeySs58: consent.coldkeySs58) : .noConsent
        } catch {
            status = .unavailable
        }
    }

    /// Back to the wallet chooser with nothing signing. Sign with wallet and
    /// Change wallet open the sheet here.
    func reset() {
        requests += 1
        connector.cancel()
        stage = .chooser
        address = ""
        addressError = nil
        walletId = nil
        challenge = nil
    }

    /// A wallet from the chooser. Every wallet takes the coldkey address
    /// first: the server's message names it, and only it may sign.
    func chooseWallet(_ walletId: String) {
        connector.cancel()
        self.walletId = walletId
        addressError = nil
        challenge = nil
        stage = .addressEntry
    }

    /// The typed coldkey: checked here, then the server's message for it
    /// goes to the wallet. Retry after a failure asks again: each challenge
    /// is used once, within 300 s.
    func submitAddress() async {
        guard let walletId else {
            reset()
            return
        }
        let coldkeySs58 = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SdkValidateSs58(coldkeySs58) else {
            addressError = String(localized: "That is not a valid Bittensor address.")
            return
        }
        addressError = nil
        requests += 1
        let request = requests
        stage = .requestingChallenge
        let challenge: SdkSnNetworkConsentChallengeResult
        do {
            challenge = try await client.challenge(coldkeySs58: coldkeySs58)
        } catch {
            guard request == requests else {
                return
            }
            stage = .failed(NetworkConsentFailure.of(error))
            return
        }
        // the sheet was left, or asked again, while this was in flight
        guard request == requests else {
            return
        }
        // the SDK session refuses an expired challenge too; this says so in
        // the consent's words
        guard now() / 1000 < challenge.expiresAt else {
            stage = .failed(.expired)
            return
        }
        self.challenge = challenge
        stage = .signing
        connector.signNetworkConsent(walletId: walletId, challenge: challenge)
    }

    /// The session accepted the wallet's signature over the challenge. The
    /// proof goes back only when it carries the server's message, byte for
    /// byte, for the coldkey it names.
    func handleProof(_ proof: BittensorWalletProofInfo) async {
        guard stage == .signing, let challenge else {
            return
        }
        guard proof.message == challenge.message, proof.address == challenge.coldkeySs58 else {
            fail(.message(BittensorWallet.errorText(code: SdkBittensorWalletErrorMessageMismatch, walletMessage: "")))
            return
        }
        stage = .submitting
        do {
            try await client.submit(coldkeySs58: proof.address, message: proof.message, signature: proof.signature)
        } catch {
            fail(NetworkConsentFailure.of(error))
            return
        }
        await refreshStatus()
        reset()
        onSigned()
    }

    /// The session refused the wallet's answer. An expired challenge needs a
    /// new one and says so in the consent's words; any other refusal stays
    /// on the connector's screen (the manual form's line, or its failure).
    func handleRefusal(_ code: String) {
        guard stage == .signing, code == SdkBittensorWalletErrorExpired else {
            return
        }
        fail(.expired)
    }

    private func fail(_ failure: NetworkConsentFailure) {
        connector.cancel()
        challenge = nil
        stage = .failed(failure)
    }
}
