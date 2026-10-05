//
//  BittensorWalletConnector.swift
//  URnetwork
//
//  The app side of the SDK's Bittensor wallet-connect session
//  (sdk/bittensor_wallet.go). The SDK decides what is signed and whether a
//  wallet's answer is acceptable; this file only moves the user through it:
//  choose a wallet, fetch the challenge, then either open the ur.io bridge in
//  the browser (Talisman on macOS: the page drives the extension and returns
//  on urnetwork://bittensor-sign-message, the scheme this app already
//  registers) or show the manual form (iOS, and TAO.com everywhere: the
//  message to sign, the coldkey address and the pasted signature).
//
//  Supported wallets are Talisman, TAO.com and WalletConnect. Talisman and
//  TAO.com publish no mobile deep link, and TAO.com publishes no extension
//  api, so those combinations are manual. WalletConnect (Nova, Nightly and
//  other substrate WalletConnect wallets) opens the ur.io bridge on both
//  iOS and macOS: the page pairs (a QR, or "Open wallet" on the phone) with
//  this app's WalletConnect project id (Info.plist URWalletConnectProjectId)
//  and returns on the same redirect link.
//

import Foundation
import URnetworkSdk
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct BittensorWalletProofInfo: Equatable {
    let walletId: String
    let purpose: String
    let address: String
    let message: String
    let signature: String
}

enum BittensorWalletOutcome: Equatable {
    case proof(BittensorWalletProofInfo)
    /// the session refused the answer; code is a BittensorWalletError* value.
    /// For wallet_error from the bridge page, walletMessage is the page's text
    /// and bridgeCode its code for the failure (BittensorWalletBridgeError*,
    /// "" from a page before the codes)
    case failed(code: String, walletMessage: String, bridgeCode: String = "")
    /// not this flow's answer (another purpose, a stray or late return):
    /// leave the flow as it is
    case ignored
}

/// The SDK session, behind a protocol so the flow logic can be tested with a
/// scripted session.
protocol BittensorWalletSessioning: AnyObject {
    var walletId: String { get }
    var purpose: String { get }
    var transport: String { get }
    var message: String { get }
    func challengeArgs(expectedAddress: String) -> SdkAuthWalletChallengeArgs?
    func setChallenge(_ result: SdkAuthWalletChallengeResult, nowMillis: Int64) throws
    func setWalletConnectProjectId(_ projectId: String)
    func bridgeUrl() throws -> String
    func isReturn(_ uri: String) -> Bool
    func handleBridgeReturn(_ uri: String, nowMillis: Int64) -> BittensorWalletOutcome
    func handleSignature(address: String, signature: String, nowMillis: Int64) -> BittensorWalletOutcome
    func cancel()
}

enum BittensorWallet {

    /// the redirect link this app registers (URnetwork-Info.plist urnetwork)
    static let redirectLink = "urnetwork://bittensor-sign-message"

    static var platform: String {
        #if os(iOS)
        return SdkBittensorWalletPlatformIos
        #else
        return SdkBittensorWalletPlatformMacos
        #endif
    }

    /// the supported wallets, in display order
    static var walletIds: [String] {
        [SdkBittensorWalletTalisman, SdkBittensorWalletTaoCom, SdkBittensorWalletWalletConnect]
    }

    /// this app's WalletConnect Cloud project id (a public client identifier;
    /// Info.plist URWalletConnectProjectId, from vault/main/walletconnect.yml)
    static var walletConnectProjectId: String {
        (Bundle.main.object(forInfoDictionaryKey: "URWalletConnectProjectId") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// product names are not translated
    static func displayName(_ walletId: String) -> String {
        SdkBittensorWalletDisplayName(walletId)
    }

    static func transport(_ walletId: String, platform: String = BittensorWallet.platform) -> String {
        SdkBittensorWalletTransportFor(walletId, platform)
    }

    /// Opens the bridge page in the default browser (the one with the
    /// extension).
    @MainActor
    static func openInBrowser(_ url: URL) -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        return true
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    static func makeSession(walletId: String, platform: String, purpose: String, redirectLink: String) throws -> BittensorWalletSessioning {
        var error: NSError?
        guard let session = SdkNewBittensorWalletSession(walletId, platform, purpose, redirectLink, &error) else {
            throw error ?? BittensorWalletConnectorError.unsupported
        }
        return SdkBittensorWalletSessionAdapter(session)
    }

    /// Codes that mean "not this flow's answer": the flow stays as it is.
    static let ignoredCodes: Set<String> = [
        SdkBittensorWalletErrorNotReturn,
        SdkBittensorWalletErrorPurposeMismatch,
        SdkBittensorWalletErrorNotAwaiting,
        // a return naming another wallet than this session's
        SdkBittensorWalletErrorUnsupportedWallet,
    ]

    static func outcome(proof: BittensorWalletProofInfo?, errorCode: String, errorMessage: String, bridgeErrorCode: String = "") -> BittensorWalletOutcome {
        if let proof, errorCode.isEmpty {
            return .proof(proof)
        }
        if ignoredCodes.contains(errorCode) {
            return .ignored
        }
        return .failed(code: errorCode, walletMessage: errorMessage, bridgeCode: bridgeErrorCode)
    }

    /// The user-facing text of a refusal. A wallet_error from the bridge page
    /// reads in this app's words for the page's code when the app knows it,
    /// else in the page's own text. walletId names the wallet in the texts
    /// that take it.
    static func errorText(code: String, walletMessage: String, bridgeCode: String = "", walletId: String = "") -> String {
        switch code {
        case SdkBittensorWalletErrorInvalidSignature:
            return String(localized: "That is not a valid signature. Paste the full 0x signature from your wallet.")
        case SdkBittensorWalletErrorExpired:
            return String(localized: "This request expired. Start again to get a new message to sign.")
        case SdkBittensorWalletErrorMessageMismatch:
            return String(localized: "The wallet signed a different request. Start again.")
        case SdkBittensorWalletErrorAddressMismatch:
            return String(localized: "The wallet that signed is not the address you entered.")
        case SdkBittensorWalletErrorInvalidAddress:
            return String(localized: "That is not a valid Bittensor address.")
        case SdkBittensorWalletErrorWallet:
            if let text = bridgeErrorText(bridgeCode, walletName: displayName(walletId)) {
                return text
            }
            // the bridge page's own text (the wallet's rejection)
            return walletMessage.isEmpty
                ? String(localized: "There was an error connecting your wallet.")
                : walletMessage
        default:
            return String(localized: "There was an error connecting your wallet.")
        }
    }

    /// This app's words for the bridge page's code for a failure (sdk
    /// BittensorWalletBridgeError*), nil for a code it does not know.
    static func bridgeErrorText(_ bridgeCode: String, walletName: String) -> String? {
        switch bridgeCode {
        case SdkBittensorWalletBridgeErrorAddressNotInWallet:
            return String(localized: "Your \(walletName) wallet doesn't have the address you entered. Add or connect that account in the wallet, or enter an address it has.")
        case SdkBittensorWalletBridgeErrorAddressMismatch:
            return String(localized: "The wallet that signed is not the address you entered.")
        case SdkBittensorWalletBridgeErrorExtensionNotFound:
            return String(localized: "The \(walletName) extension was not found in this browser. Install it, then try again.")
        case SdkBittensorWalletBridgeErrorNoAccount:
            return String(localized: "Your \(walletName) wallet has no account to sign with. Add or connect an account in the wallet, then try again.")
        case SdkBittensorWalletBridgeErrorUserRejected:
            return String(localized: "The request was declined in your wallet. Start again and approve it to continue.")
        case SdkBittensorWalletBridgeErrorWalletConnectExpired:
            return String(localized: "The WalletConnect request expired before the wallet answered. Start again.")
        case SdkBittensorWalletBridgeErrorWalletConnectUnavailable:
            return String(localized: "WalletConnect is not available right now. Try again later, or enter your address manually.")
        default:
            return nil
        }
    }
}

enum BittensorWalletConnectorError: Error {
    case unsupported
}

final class SdkBittensorWalletSessionAdapter: BittensorWalletSessioning {

    private let session: SdkBittensorWalletSession

    init(_ session: SdkBittensorWalletSession) {
        self.session = session
    }

    var walletId: String { session.walletId() }
    var purpose: String { session.purpose() }
    var transport: String { session.transport() }
    var message: String { session.message() }

    func challengeArgs(expectedAddress: String) -> SdkAuthWalletChallengeArgs? {
        session.challengeArgs(expectedAddress)
    }

    func setChallenge(_ result: SdkAuthWalletChallengeResult, nowMillis: Int64) throws {
        try session.setChallenge(result, nowMillis: nowMillis)
    }

    func setWalletConnectProjectId(_ projectId: String) {
        session.setWalletConnectProjectId(projectId)
    }

    func bridgeUrl() throws -> String {
        var error: NSError?
        let url = session.bridgeUrl(&error)
        if let error {
            throw error
        }
        return url
    }

    func isReturn(_ uri: String) -> Bool {
        session.isReturn(uri)
    }

    func handleBridgeReturn(_ uri: String, nowMillis: Int64) -> BittensorWalletOutcome {
        Self.outcome(session.handleBridgeReturn(uri, nowMillis: nowMillis))
    }

    func handleSignature(address: String, signature: String, nowMillis: Int64) -> BittensorWalletOutcome {
        Self.outcome(session.handleSignature(address, signature: signature, nowMillis: nowMillis))
    }

    func cancel() {
        session.cancel()
    }

    private static func outcome(_ result: SdkBittensorWalletResult?) -> BittensorWalletOutcome {
        guard let result else {
            return .failed(code: "", walletMessage: "")
        }
        let proof = result.proof.map {
            BittensorWalletProofInfo(
                walletId: $0.walletId,
                purpose: $0.purpose,
                address: $0.address,
                message: $0.message,
                signature: $0.signature
            )
        }
        return BittensorWallet.outcome(
            proof: proof,
            errorCode: result.errorCode,
            errorMessage: result.errorMessage,
            bridgeErrorCode: result.bridgeErrorCode
        )
    }
}

/// One wallet proof at a time, for one screen. The screen shows the chooser,
/// the manual form or the "continue in your browser" state from `stage`, and
/// receives the proof through `onProof`.
@MainActor
final class BittensorWalletConnector: ObservableObject {

    enum Stage: Equatable {
        case idle
        case choosing
        case requestingChallenge(walletId: String)
        /// the manual form: sign `message` elsewhere, paste address + signature
        case manualSignature(walletId: String, message: String)
        /// the bridge is open in the browser
        case awaitingBrowser(walletId: String)
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published var manualAddress: String = ""
    @Published var manualSignature: String = ""
    /// the address was given before signing (bound into the challenge)
    @Published private(set) var addressLocked = false
    @Published private(set) var manualError: String?

    /// awaited, so a caller (and a test) sees the whole hand-off finish
    var onProof: (BittensorWalletProofInfo) async -> Void = { _ in }

    private let platform: String
    private let redirectLink: String
    private let makeSession: (_ walletId: String, _ platform: String, _ purpose: String, _ redirectLink: String) throws -> BittensorWalletSessioning
    private let fetchChallenge: (SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult
    private let openUrl: @MainActor (URL) -> Bool
    private let now: () -> Int64
    private let walletConnectProjectId: String

    private var session: BittensorWalletSessioning?
    private(set) var lastWalletId: String?

    init(
        platform: String = BittensorWallet.platform,
        redirectLink: String = BittensorWallet.redirectLink,
        makeSession: @escaping (_ walletId: String, _ platform: String, _ purpose: String, _ redirectLink: String) throws -> BittensorWalletSessioning = BittensorWallet.makeSession,
        fetchChallenge: @escaping (SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult,
        openUrl: @escaping @MainActor (URL) -> Bool = BittensorWallet.openInBrowser,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        walletConnectProjectId: String = BittensorWallet.walletConnectProjectId
    ) {
        self.walletConnectProjectId = walletConnectProjectId
        self.platform = platform
        self.redirectLink = redirectLink
        self.makeSession = makeSession
        self.fetchChallenge = fetchChallenge
        self.openUrl = openUrl
        self.now = now
    }

    var isActive: Bool {
        stage != .idle
    }

    func presentChooser() {
        cancelSession()
        manualError = nil
        stage = .choosing
    }

    /// Starts a proof with the chosen wallet. A non-empty expectedAddress
    /// binds the challenge to it and pre-fills (and locks) the manual form.
    func choose(walletId: String, purpose: String, expectedAddress: String = "") async {
        cancelSession()
        lastWalletId = walletId
        manualError = nil
        manualSignature = ""
        manualAddress = expectedAddress
        addressLocked = !expectedAddress.isEmpty
        stage = .requestingChallenge(walletId: walletId)

        let session: BittensorWalletSessioning
        do {
            session = try makeSession(walletId, platform, purpose, redirectLink)
        } catch {
            stage = .failed(BittensorWallet.errorText(code: "", walletMessage: ""))
            return
        }
        self.session = session
        if walletId == SdkBittensorWalletWalletConnect {
            session.setWalletConnectProjectId(walletConnectProjectId)
        }
        do {
            guard let args = session.challengeArgs(expectedAddress: expectedAddress) else {
                throw BittensorWalletConnectorError.unsupported
            }
            let result = try await fetchChallenge(args)
            // abandoned while the challenge was in flight
            guard self.session === session else {
                return
            }
            try session.setChallenge(result, nowMillis: now())
        } catch {
            guard self.session === session else {
                return
            }
            stage = .failed(BittensorWallet.errorText(code: "", walletMessage: ""))
            return
        }

        if session.transport == SdkBittensorWalletTransportBrowserBridge {
            guard let bridgeUrl = try? session.bridgeUrl(), let url = URL(string: bridgeUrl), openUrl(url) else {
                stage = .failed(BittensorWallet.errorText(code: "", walletMessage: ""))
                return
            }
            stage = .awaitingBrowser(walletId: walletId)
        } else {
            stage = .manualSignature(walletId: walletId, message: session.message)
        }
    }

    /// The manual form's Continue. A refusal stays on the form with the
    /// reason, except an expired challenge, which needs a new one.
    func submitManual() async {
        guard let session, case .manualSignature = stage else {
            return
        }
        switch session.handleSignature(address: manualAddress, signature: manualSignature, nowMillis: now()) {
        case .proof(let proof):
            await finish(proof)
        case .failed(let code, let walletMessage, _):
            if code == SdkBittensorWalletErrorExpired {
                stage = .failed(BittensorWallet.errorText(code: code, walletMessage: walletMessage))
            } else {
                manualError = BittensorWallet.errorText(code: code, walletMessage: walletMessage)
            }
        case .ignored:
            break
        }
    }

    /// Whether an incoming url is a bridge hand-back on this connector's
    /// redirect link while a session is open (route it to
    /// handleBridgeReturn, not to another handler).
    func isBridgeReturn(_ url: URL) -> Bool {
        session?.isReturn(url.absoluteString) ?? false
    }

    /// A bridge hand-back. One for another flow (purpose), a stray or a late
    /// one is ignored.
    func handleBridgeReturn(_ url: URL) async {
        guard let session, session.isReturn(url.absoluteString) else {
            return
        }
        switch session.handleBridgeReturn(url.absoluteString, nowMillis: now()) {
        case .proof(let proof):
            await finish(proof)
        case .failed(let code, let walletMessage, let bridgeCode):
            stage = .failed(BittensorWallet.errorText(
                code: code,
                walletMessage: walletMessage,
                bridgeCode: bridgeCode,
                walletId: session.walletId
            ))
        case .ignored:
            break
        }
    }

    func cancel() {
        cancelSession()
        stage = .idle
        manualError = nil
    }

    private func finish(_ proof: BittensorWalletProofInfo) async {
        session = nil
        stage = .idle
        manualError = nil
        await onProof(proof)
    }

    private func cancelSession() {
        session?.cancel()
        session = nil
    }
}
