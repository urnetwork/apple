//
//  NetworkConsentFlowTests.swift
//  networkTests
//
//  The network payout consent (VERSION2-FINAL §11.1, CONSENT.md §4, §8, §9).
//  It covers:
//  - no consent, then signing, then active from the next epoch;
//  - a change of wallet;
//  - the consent's own refusals (expired, signature mismatch, not the
//    network owner) and every other error;
//  - the app signing only the server's message, verbatim.
//  A scripted client stands in for the SDK. The wallet answers through a
//  scripted session behind the shared connector, or through the real SDK
//  session where its checks matter, with a fixed clock and no network.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

// well-known Substrate dev accounts (subkey //Alice, //Bob)
private let alice = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
private let bob = "5FHneW46xGXgs5mUiveU4sbTyGBzmstUspZC92UhjJM694ty"
private let consentSignature = "0x" + String(repeating: "ab", count: 64)
private let consentNowMillis: Int64 = 1_757_340_000_000
/// the epoch the consent is signed in; the operator accepts it only from the
/// next one
private let currentEpoch: Int64 = 42
/// a bridge hand-back; the scripted session answers it whatever it carries
private let consentReturn = URL(string: "urnetwork://bittensor-sign-message?purpose=consent")!

/// A consent message as the server words it, for a coldkey. Its JSON holds
/// the characters a query string can mangle: "+", "&", "=", "%", "/", a space.
private func consentMessage(for coldkey: String) -> String {
    "Approve URnetwork network wallet mapping\n{\"schema\":\"urnetwork-network-wallet-mapping-consent-v1\",\"scope\":\"network\",\"coldkey\":\"\(coldkey)\",\"nonce\":\"q+1&w=2%3/e r\",\"issued_at\":1757340000,\"expires_at\":1757340300,\"from_epoch\":43,\"through_epoch\":65578}"
}

/// A challenge as SnNetworkConsentChallenge returns it: from the next epoch,
/// until changed, for 300 s.
private func consentChallenge(_ coldkey: String) -> SdkSnNetworkConsentChallengeResult {
    let result = SdkSnNetworkConsentChallengeResult()
    result.message = consentMessage(for: coldkey)
    result.coldkeySs58 = coldkey
    result.fromEpoch = currentEpoch + 1
    result.throughEpoch = currentEpoch + 1 + 65535
    result.expiresAt = consentNowMillis / 1000 + 300
    return result
}

/// An error as the SDK hands one over (gomobile: the Go error's text).
private func sdkError(_ message: String) -> Error {
    NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private struct Submission: Equatable {
    let coldkeySs58: String
    let message: String
    let signature: String
}

/// The scripted SDK client. It records every call and answers as the SDK
/// and the server do where that matters: a stored consent starts next epoch
/// and is active from then on.
@MainActor
private final class FakeConsentClient: NetworkConsentClient {

    var consent = NetworkConsentStatusInfo(active: false, coldkeySs58: "", fromEpoch: 0, throughEpoch: 0)
    var statusError: Error?
    var challengeError: Error?
    var submitError: Error?
    /// runs in challenge() after the call is recorded, before it returns
    var beforeChallengeReturns: () async -> Void = {}

    private(set) var challengeRequests: [String] = []
    private(set) var issued: [SdkSnNetworkConsentChallengeResult] = []
    private(set) var submissions: [Submission] = []

    func status() async throws -> NetworkConsentStatusInfo {
        if let statusError {
            throw statusError
        }
        return consent
    }

    func challenge(coldkeySs58: String) async throws -> SdkSnNetworkConsentChallengeResult {
        challengeRequests.append(coldkeySs58)
        await beforeChallengeReturns()
        if let challengeError {
            throw challengeError
        }
        let result = consentChallenge(coldkeySs58)
        issued.append(result)
        return result
    }

    func submit(coldkeySs58: String, message: String, signature: String) async throws {
        submissions.append(Submission(coldkeySs58: coldkeySs58, message: message, signature: signature))
        if let submitError {
            throw submitError
        }
        consent = NetworkConsentStatusInfo(
            active: true,
            coldkeySs58: coldkeySs58,
            fromEpoch: currentEpoch + 1,
            throughEpoch: currentEpoch + 1 + 65535
        )
    }
}

/// The scripted wallet behind the shared connector. It takes a consent
/// challenge the way the SDK session does (verbatim, bound to its coldkey,
/// refused once expired). It answers the bridge or the manual form with a
/// signature over the message it holds, or over `signedMessage`.
private final class ScriptedConsentSession: BittensorWalletSessioning {

    let walletId: String
    let purpose: String
    let transport: String
    private(set) var message = ""
    /// every challenge the connector handed over, as handed over
    private(set) var challenges: [SdkSnNetworkConsentChallengeResult] = []
    /// the text the wallet signs instead of the message it was given
    var signedMessage: String?
    /// the wallet's answer instead of a signature
    var refusal: BittensorWalletOutcome?
    private var coldkeySs58 = ""
    private var expiresAtMillis: Int64 = 0
    private var open = true

    init(walletId: String, platform: String, purpose: String) {
        self.walletId = walletId
        self.purpose = purpose
        self.transport = BittensorWallet.transport(walletId, platform: platform)
    }

    func challengeArgs(expectedAddress: String) -> SdkAuthWalletChallengeArgs? {
        nil
    }

    func setChallenge(_ result: SdkAuthWalletChallengeResult, nowMillis: Int64) throws {
        // a consent session takes no sign-in challenge
        throw BittensorWalletConnectorError.unsupported
    }

    func setNetworkConsentChallenge(_ result: SdkSnNetworkConsentChallengeResult, nowMillis: Int64) throws {
        challenges.append(result)
        message = result.message
        coldkeySs58 = result.coldkeySs58
        expiresAtMillis = result.expiresAt * 1000
    }

    func setWalletConnectProjectId(_ projectId: String) {}

    func bridgeUrl() throws -> String {
        "https://ur.io/bittensor-connect?purpose=\(purpose)"
    }

    func isReturn(_ uri: String) -> Bool {
        open && uri.hasPrefix(BittensorWallet.redirectLink)
    }

    func handleBridgeReturn(_ uri: String, nowMillis: Int64) -> BittensorWalletOutcome {
        answer(address: coldkeySs58, signature: consentSignature, nowMillis: nowMillis)
    }

    func handleSignature(address: String, signature: String, nowMillis: Int64) -> BittensorWalletOutcome {
        answer(address: address, signature: signature, nowMillis: nowMillis)
    }

    func cancel() {
        open = false
    }

    private func answer(address: String, signature: String, nowMillis: Int64) -> BittensorWalletOutcome {
        if let refusal {
            return refusal
        }
        guard nowMillis < expiresAtMillis else {
            return .failed(code: SdkBittensorWalletErrorExpired, walletMessage: "")
        }
        return .proof(BittensorWalletProofInfo(
            walletId: walletId,
            purpose: purpose,
            address: address,
            message: signedMessage ?? message,
            signature: signature
        ))
    }
}

/// What the connector did: the clock it reads, the pages it opened and the
/// sessions it made.
private final class WalletRecorder {
    var nowMillis = consentNowMillis
    var opened: [URL] = []
    var sessions: [ScriptedConsentSession] = []
}

/// Holds a scripted challenge open until the test releases it.
@MainActor
private final class ConsentGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
struct NetworkConsentFlowTests {

    /// a flow whose connector signs through scripted sessions
    private static func flow(platform: String, client: FakeConsentClient, recorder: WalletRecorder) -> NetworkConsentFlow {
        let connector = BittensorWalletConnector(
            platform: platform,
            makeSession: { walletId, platform, purpose, _ in
                let session = ScriptedConsentSession(walletId: walletId, platform: platform, purpose: purpose)
                recorder.sessions.append(session)
                return session
            },
            fetchChallenge: { _ in
                throw BittensorWalletConnectorError.unsupported
            },
            openUrl: { url in
                recorder.opened.append(url)
                return true
            },
            now: { recorder.nowMillis }
        )
        return NetworkConsentFlow(client: client, platform: platform, connector: connector, now: { recorder.nowMillis })
    }

    /// up to the wallet: the wallet chosen, the coldkey typed, the challenge
    /// handed to the connector
    private static func signing(
        _ coldkey: String = alice,
        walletId: String = SdkBittensorWalletTalisman,
        platform: String = SdkBittensorWalletPlatformMacos,
        client: FakeConsentClient? = nil
    ) async -> (FakeConsentClient, WalletRecorder, NetworkConsentFlow) {
        let client = client ?? FakeConsentClient()
        let recorder = WalletRecorder()
        let flow = Self.flow(platform: platform, client: client, recorder: recorder)
        flow.reset()
        flow.chooseWallet(walletId)
        flow.address = coldkey
        await flow.submitAddress()
        return (client, recorder, flow)
    }

    /// a bridge hand-back as the page builds it: URLSearchParams form
    /// encoding, so the "+", "&" and "=" of a value arrive escaped
    private static func returnUrl(_ items: [String: String]) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var components = URLComponents(string: BittensorWallet.redirectLink)!
        components.percentEncodedQuery = items.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
        return components.url!
    }

    // MARK: signing

    // CS-7: no consent, then the wallet signs the server's message, then the
    // consent shows active, from the next epoch
    @Test func noConsentThenSigningThenActiveFromTheNextEpoch() async throws {
        let client = FakeConsentClient()
        let recorder = WalletRecorder()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, client: client, recorder: recorder)
        var signed = 0
        flow.onSigned = { signed += 1 }
        #expect(flow.status == .loading)

        await flow.refreshStatus()
        #expect(flow.status == .noConsent)

        flow.reset()
        flow.chooseWallet(SdkBittensorWalletTalisman)
        // the server's message names the coldkey: every wallet takes it first
        #expect(flow.stage == .addressEntry)
        #expect(client.challengeRequests.isEmpty)

        flow.address = " \(alice) "
        await flow.submitAddress()
        #expect(client.challengeRequests == [alice])
        #expect(flow.stage == .signing)
        #expect(flow.connector.stage == .awaitingBrowser(walletId: SdkBittensorWalletTalisman))
        // "Waiting for your wallet's signature…"
        #expect(flow.awaitingSignature)
        #expect(recorder.opened.count == 1)
        let session = try #require(recorder.sessions.last)
        #expect(session.purpose == SdkBittensorWalletPurposeConsent)

        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(client.submissions == [Submission(coldkeySs58: alice, message: consentMessage(for: alice), signature: consentSignature)])
        // the status read after the submission: active, starting next epoch
        #expect(flow.status == .active(coldkeySs58: alice))
        #expect(client.consent.fromEpoch == currentEpoch + 1)
        #expect(signed == 1)
        #expect(flow.stage == .chooser)
    }

    // CS-7: a manual wallet (TAO.com on iOS) shows the server's message with
    // the coldkey locked, and the pasted signature goes back with it
    @Test func aManualWalletSignsTheMessageForTheTypedColdkey() async {
        let (client, recorder, flow) = await Self.signing(walletId: SdkBittensorWalletTaoCom, platform: SdkBittensorWalletPlatformIos)
        #expect(flow.connector.stage == .manualSignature(walletId: SdkBittensorWalletTaoCom, message: consentMessage(for: alice)))
        #expect(flow.connector.manualAddress == alice)
        #expect(flow.connector.addressLocked)
        #expect(flow.awaitingSignature)
        #expect(recorder.opened.isEmpty)

        flow.connector.manualSignature = consentSignature
        await flow.connector.submitManual()
        #expect(client.submissions == [Submission(coldkeySs58: alice, message: consentMessage(for: alice), signature: consentSignature)])
        #expect(flow.status == .active(coldkeySs58: alice))
    }

    // CS-7: only a consent the status calls active shows as active, and one
    // that starts next epoch is active (CONSENT.md §8); a status that could
    // not be read is not "no consent"
    @Test func onlyAnActiveConsentShowsAndAnUnreadOneIsUnavailable() async {
        let client = FakeConsentClient()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, client: client, recorder: WalletRecorder())

        client.consent = NetworkConsentStatusInfo(active: true, coldkeySs58: alice, fromEpoch: currentEpoch + 1, throughEpoch: currentEpoch + 1 + 65535)
        await flow.refreshStatus()
        #expect(flow.status == .active(coldkeySs58: alice))

        // past its through_epoch
        client.consent = NetworkConsentStatusInfo(active: false, coldkeySs58: alice, fromEpoch: 1, throughEpoch: 2)
        await flow.refreshStatus()
        #expect(flow.status == .noConsent)

        client.statusError = sdkError("server_error: 502 Bad Gateway")
        await flow.refreshStatus()
        #expect(flow.status == .unavailable)
    }

    // CS-8: with a consent, Change wallet signs a new one for another
    // coldkey, which the status shows from the next epoch
    @Test func changingTheWalletSignsANewConsentFromTheNextEpoch() async {
        let client = FakeConsentClient()
        client.consent = NetworkConsentStatusInfo(active: true, coldkeySs58: alice, fromEpoch: 40, throughEpoch: 40 + 65535)
        let recorder = WalletRecorder()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformIos, client: client, recorder: recorder)
        await flow.refreshStatus()
        #expect(flow.status == .active(coldkeySs58: alice))

        flow.reset()
        flow.chooseWallet(SdkBittensorWalletWalletConnect)
        flow.address = bob
        await flow.submitAddress()
        #expect(client.challengeRequests == [bob])
        #expect(flow.connector.stage == .awaitingBrowser(walletId: SdkBittensorWalletWalletConnect))

        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(client.submissions == [Submission(coldkeySs58: bob, message: consentMessage(for: bob), signature: consentSignature)])
        #expect(flow.status == .active(coldkeySs58: bob))
        #expect(client.consent.fromEpoch == currentEpoch + 1)
    }

    // an address that is not a Bittensor address, or no wallet chosen, asks
    // for no challenge
    @Test func anInvalidColdkeyIsRefusedBeforeTheChallenge() async {
        let client = FakeConsentClient()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformIos, client: client, recorder: WalletRecorder())

        // no wallet chosen: back to the chooser
        flow.address = alice
        await flow.submitAddress()
        #expect(flow.stage == .chooser)
        #expect(flow.address.isEmpty)
        #expect(client.challengeRequests.isEmpty)

        flow.chooseWallet(SdkBittensorWalletTaoCom)
        flow.address = "5NotABittensorAddress"
        await flow.submitAddress()
        #expect(flow.addressError == String(localized: "That is not a valid Bittensor address."))
        #expect(flow.stage == .addressEntry)
        #expect(client.challengeRequests.isEmpty)
    }

    // a challenge answered after the sheet was left goes to no wallet
    @Test func aChallengeAnsweredAfterTheSheetWasLeftIsDropped() async {
        let client = FakeConsentClient()
        let gate = ConsentGate()
        client.beforeChallengeReturns = {
            await gate.wait()
        }
        let recorder = WalletRecorder()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, client: client, recorder: recorder)
        flow.chooseWallet(SdkBittensorWalletTalisman)
        flow.address = alice

        let request = Task {
            await flow.submitAddress()
        }
        for _ in 0..<100 where client.challengeRequests.isEmpty {
            await Task.yield()
        }
        #expect(client.challengeRequests == [alice])
        #expect(flow.stage == .requestingChallenge)
        #expect(flow.awaitingSignature)

        flow.reset()
        gate.open()
        await request.value
        #expect(flow.stage == .chooser)
        #expect(recorder.sessions.isEmpty)
        #expect(recorder.opened.isEmpty)
    }

    // MARK: refusals

    // CS-6: each refusal reads in its own words, from the SDK's code
    @Test func eachRefusalReadsInItsOwnWords() {
        // the codes the SDK pins (CONSENT.md §7, §9)
        #expect(SdkSnErrorCodeNetworkOwnerOnly == "network_owner_only")
        #expect(SdkSnErrorCodeChallengeExpired == "challenge_expired")
        #expect(SdkBittensorWalletPurposeConsent == "consent")

        #expect(NetworkConsentFailure.of(sdkError("network_owner_only: no network credential")) == .ownerOnly)
        #expect(NetworkConsentFailure.of(sdkError("challenge_expired: the consent challenge expired")) == .expired)
        #expect(NetworkConsentFailure.of(EarningsClientError.signatureMismatch("The signature does not match this coldkey address.")) == .signatureMismatch)
        #expect(NetworkConsentFailure.of(sdkError("server_error: 500 Internal Server Error")) == .message("server_error: 500 Internal Server Error"))

        #expect(NetworkConsentFailure.expired.text == String(localized: "The request expired. Try again."))
        #expect(NetworkConsentFailure.signatureMismatch.text == String(localized: "The signature didn't match this wallet. Try again."))
        #expect(NetworkConsentFailure.ownerOnly.text == String(localized: "Only the network owner can choose the payout wallet."))
        #expect(NetworkConsentFailure.message("server_error: 500").text == "server_error: 500")
    }

    // CS-6: a signature that comes back after the challenge expired is
    // refused in the consent's words, nothing is submitted, and Retry asks
    // for a new challenge
    @Test func aSignatureAfterTheChallengeExpiredSaysTheRequestExpired() async {
        let (client, recorder, flow) = await Self.signing()
        recorder.nowMillis += 300 * 1000

        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(flow.stage == .failed(.expired))
        #expect(flow.connector.stage == .idle)
        #expect(client.submissions.isEmpty)

        recorder.nowMillis = consentNowMillis
        await flow.submitAddress()
        #expect(client.challengeRequests == [alice, alice])
        #expect(flow.stage == .signing)
    }

    // CS-6: the manual form's late signature reads the same
    @Test func aManualSignatureAfterTheChallengeExpiredSaysTheRequestExpired() async {
        let (client, recorder, flow) = await Self.signing(walletId: SdkBittensorWalletTaoCom, platform: SdkBittensorWalletPlatformIos)
        recorder.nowMillis += 300 * 1000

        flow.connector.manualSignature = consentSignature
        await flow.connector.submitManual()
        #expect(flow.stage == .failed(.expired))
        #expect(client.submissions.isEmpty)
    }

    // CS-6: the server refused the submission as expired
    @Test func anExpiredSubmissionSaysTheRequestExpired() async {
        let client = FakeConsentClient()
        client.submitError = sdkError("challenge_expired: network wallet mapping original challenge is expired or not yet effective")
        let (_, _, flow) = await Self.signing(client: client)

        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(client.submissions.count == 1)
        #expect(flow.stage == .failed(.expired))
        #expect(flow.status == .loading)
    }

    // CS-6: a challenge already expired when it arrives (the device clock
    // runs 300 s ahead) never reaches the wallet
    @Test func aChallengeExpiredOnArrivalIsNotSigned() async {
        let client = FakeConsentClient()
        let recorder = WalletRecorder()
        recorder.nowMillis = consentNowMillis + 300 * 1000
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, client: client, recorder: recorder)
        flow.chooseWallet(SdkBittensorWalletTalisman)
        flow.address = alice
        await flow.submitAddress()

        #expect(flow.stage == .failed(.expired))
        #expect(recorder.sessions.isEmpty)
        #expect(recorder.opened.isEmpty)
    }

    // CS-6: a signature that does not verify for the coldkey
    @Test func aSignatureMismatchSaysTheSignatureDidNotMatch() async {
        let client = FakeConsentClient()
        client.submitError = EarningsClientError.signatureMismatch("The signature does not match this coldkey address.")
        let (_, _, flow) = await Self.signing(client: client)

        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(client.submissions.count == 1)
        #expect(flow.stage == .failed(.signatureMismatch))
        #expect(flow.status == .loading)
    }

    // CS-6: POST /sn/wallet's refusal through the SDK client: the mismatch
    // keeps its own case, any other reads "code: message"
    @Test func theSdkClientKeepsTheSignatureMismatch() {
        func refusal(code: String, message: String) -> SdkSnSetWalletError {
            let error = SdkSnSetWalletError()
            error.code = code
            error.message = message
            return error
        }
        #expect(NetworkConsentSdkClient.error(refusal(code: "signature_mismatch", message: "The signature does not match this coldkey address.")) == .signatureMismatch("The signature does not match this coldkey address."))
        #expect(NetworkConsentSdkClient.error(refusal(code: "server_error", message: "400 bad consent")) == .message("server_error: 400 bad consent"))
        #expect(NetworkConsentSdkClient.error(refusal(code: "", message: "refused")) == .message("refused"))
        #expect(NetworkConsentSdkClient.error(refusal(code: "challenge_expired", message: "")) == .message("challenge_expired"))
        #expect(NetworkConsentSdkClient.error(nil) == nil)
        // a coded refusal reads in the consent's words
        #expect(NetworkConsentFailure.of(EarningsClientError.message("challenge_expired")) == .expired)
    }

    // CS-6: a session that is not the network owner's is told so, and no
    // wallet is asked
    @Test func aSessionThatIsNotTheOwnersIsToldOnlyTheOwnerCan() async {
        let client = FakeConsentClient()
        client.challengeError = sdkError("network_owner_only: no network credential")
        let (_, recorder, flow) = await Self.signing(client: client)

        #expect(client.challengeRequests == [alice])
        #expect(flow.stage == .failed(.ownerOnly))
        #expect(recorder.sessions.isEmpty)
        #expect(recorder.opened.isEmpty)
        #expect(client.submissions.isEmpty)
    }

    // CS-6: any other error shows as the SDK wrote it, a refused challenge as
    // much as a refused submission
    @Test func otherErrorsShowAsTheSdkWroteThem() async {
        let client = FakeConsentClient()
        client.challengeError = sdkError("server_error: 500 Internal Server Error")
        let (_, recorder, flow) = await Self.signing(client: client)
        #expect(flow.stage == .failed(.message("server_error: 500 Internal Server Error")))
        #expect(recorder.sessions.isEmpty)

        client.challengeError = nil
        client.submitError = EarningsClientError.message("server_error: 400 bad consent")
        await flow.submitAddress()
        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(flow.stage == .failed(.message("server_error: 400 bad consent")))
    }

    // CS-6: the wallet's own refusal shows on the connector's screen, with
    // its Retry, and nothing is submitted
    @Test func theWalletsOwnRefusalStaysOnTheConnectorsScreen() async throws {
        let (client, recorder, flow) = await Self.signing()
        let session = try #require(recorder.sessions.last)
        session.refusal = .failed(code: SdkBittensorWalletErrorWallet, walletMessage: "Cancelled", bridgeCode: SdkBittensorWalletBridgeErrorUserRejected)

        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(flow.connector.stage == .failed(String(localized: "The request was declined in your wallet. Start again and approve it to continue.")))
        #expect(flow.stage == .signing)
        #expect(!flow.awaitingSignature)
        #expect(client.submissions.isEmpty)
    }

    // MARK: verbatim

    // CS-9: the wallet gets the challenge the SDK issued, unchanged, and a
    // signature over any other text is not sent
    @Test func theAppSignsOnlyTheServersMessageVerbatim() async throws {
        let (client, recorder, flow) = await Self.signing()
        let session = try #require(recorder.sessions.last)
        let issued = try #require(client.issued.last)
        #expect(session.challenges.count == 1)
        let handed = try #require(session.challenges.first)
        #expect(handed === issued)
        #expect(session.message == consentMessage(for: alice))

        session.signedMessage = consentMessage(for: bob)
        await flow.connector.handleBridgeReturn(consentReturn)
        #expect(client.submissions.isEmpty)
        #expect(flow.stage == .failed(.message(String(localized: "The wallet signed a different request. Start again."))))

        await flow.submitAddress()
        await flow.connector.handleBridgeReturn(consentReturn)
        let submitted = try #require(client.submissions.first)
        #expect(client.submissions.count == 1)
        #expect(Array(submitted.message.utf8) == Array(consentMessage(for: alice).utf8))
        #expect(submitted.coldkeySs58 == alice)
    }

    // CS-9: through the real SDK session, the bridge page gets exactly the
    // server's message, for the coldkey it names, under the consent purpose;
    // a return over other text is refused, and the right one goes back as
    // issued
    @Test func theRealSessionCarriesTheServersMessageToTheWallet() async throws {
        let client = FakeConsentClient()
        let recorder = WalletRecorder()
        let connector = BittensorWalletConnector(
            platform: SdkBittensorWalletPlatformMacos,
            fetchChallenge: { _ in
                throw BittensorWalletConnectorError.unsupported
            },
            openUrl: { url in
                recorder.opened.append(url)
                return true
            },
            now: { recorder.nowMillis },
            walletConnectProjectId: "app-project"
        )
        let flow = NetworkConsentFlow(client: client, platform: SdkBittensorWalletPlatformMacos, connector: connector, now: { recorder.nowMillis })
        flow.chooseWallet(SdkBittensorWalletTalisman)
        flow.address = alice
        await flow.submitAddress()
        #expect(connector.stage == .awaitingBrowser(walletId: SdkBittensorWalletTalisman))

        let opened = try #require(recorder.opened.first)
        let components = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        // the page reads the query with URLSearchParams: form encoding, "+" is a space
        let query = Dictionary(uniqueKeysWithValues: (components.percentEncodedQueryItems ?? []).map {
            ($0.name, ($0.value ?? "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "")
        })
        #expect(query["message"] == consentMessage(for: alice))
        #expect(query["purpose"] == SdkBittensorWalletPurposeConsent)
        #expect(query["address"] == alice)
        #expect(query["wallet"] == SdkBittensorWalletTalisman)

        let other = Self.returnUrl(["address": alice, "signature": consentSignature, "message": consentMessage(for: bob), "purpose": "consent", "wallet": "talisman"])
        await connector.handleBridgeReturn(other)
        #expect(connector.stage == .failed(String(localized: "The wallet signed a different request. Start again.")))
        #expect(client.submissions.isEmpty)

        await flow.submitAddress()
        let good = Self.returnUrl(["address": alice, "signature": consentSignature, "message": consentMessage(for: alice), "purpose": "consent", "wallet": "talisman"])
        await connector.handleBridgeReturn(good)
        #expect(client.submissions == [Submission(coldkeySs58: alice, message: consentMessage(for: alice), signature: consentSignature)])
        #expect(flow.status == .active(coldkeySs58: alice))
    }
}
