import XCTest
import URnetworkSdk
@testable import URnetwork

// The add sign-in method sheet offers the same options on every app and on
// ur.io: Apple, Google, a Solana or Bittensor wallet, and an email or phone.
// The apple sheet had no Bittensor wallet, and the macOS App Store build
// showed "Apple Sign-In is available on iOS." although its login signs in
// with Apple natively.
//
// Adding a Bittensor wallet runs the shared wallet session under the "add"
// purpose and only ever calls AddAuth: a sign-in return is never added, an
// add return never reaches the login session, and nothing signs in. The SDK
// session is the real one; the challenge, the browser and the clock are
// injected, so nothing waits or touches the network.
@MainActor
final class AddAuthParityTests: XCTestCase {

    // well-known Substrate dev account (subkey //Alice)
    private static let alice = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
    nonisolated private static let message = "Sign in to URnetwork\nChallenge: q1w2e3r4t5y6u7i8o9p0\nTimestamp: 1757340000"
    private static let signature = "0x" + String(repeating: "ab", count: 64)
    private static let nowMillis: Int64 = 1_757_340_000_000

    private final class Recorder {
        var challengeArgs: [SdkAuthWalletChallengeArgs] = []
        var opened: [URL] = []
        var added: [SdkAddAuthArgs] = []
        var addedCount = 0
    }

    // records every call that could sign in or replace the session
    private final class FakeApi: MockUrApiService {
        var challengeArgs: [SdkAuthWalletChallengeArgs] = []
        var added: [SdkAddAuthArgs] = []
        var signInCalls: [String] = []

        override func authWalletChallenge(_ args: SdkAuthWalletChallengeArgs) async throws -> SdkAuthWalletChallengeResult {
            challengeArgs.append(args)
            return AddAuthParityTests.challengeResult()
        }

        override func addAuth(_ args: SdkAddAuthArgs) async throws -> SdkAddAuthResult {
            added.append(args)
            return SdkAddAuthResult()
        }

        override func authLogin(_ args: SdkAuthLoginArgs) async throws -> AuthLoginResult {
            signInCalls.append("authLogin")
            return try await super.authLogin(args)
        }

        override func createNetwork(_ args: SdkNetworkCreateArgs) async throws -> LoginNetworkResult {
            signInCalls.append("createNetwork")
            return try await super.createNetwork(args)
        }

        override func loginWithSeedphrase(seedphrase: String) async throws -> AuthLoginResult {
            signInCalls.append("loginWithSeedphrase")
            return try await super.loginWithSeedphrase(seedphrase: seedphrase)
        }

        override func authVerify(_ args: SdkAuthVerifyArgs) async throws -> SdkAuthVerifyResult {
            signInCalls.append("authVerify")
            return try await super.authVerify(args)
        }
    }

    nonisolated private static func challengeResult() -> SdkAuthWalletChallengeResult {
        let result = SdkAuthWalletChallengeResult()
        result.messageTemplate = message
        result.expiresIn = 300
        return result
    }

    private static func returnUrl(purpose: String) -> URL {
        var components = URLComponents(string: BittensorWallet.redirectLink)!
        components.queryItems = [
            URLQueryItem(name: "address", value: alice),
            URLQueryItem(name: "message", value: message),
            URLQueryItem(name: "purpose", value: purpose),
            URLQueryItem(name: "signature", value: signature),
            URLQueryItem(name: "wallet", value: SdkBittensorWalletTalisman),
        ]
        return components.url!
    }

    private static func connector(platform: String, recorder: Recorder) -> BittensorWalletConnector {
        BittensorWalletConnector(
            platform: platform,
            fetchChallenge: { args in
                recorder.challengeArgs.append(args)
                return challengeResult()
            },
            openUrl: { url in
                recorder.opened.append(url)
                return true
            },
            now: { nowMillis }
        )
    }

    private static func flow(platform: String, recorder: Recorder) -> AddAuthBittensorFlow {
        let flow = AddAuthBittensorFlow(
            connector: connector(platform: platform, recorder: recorder),
            addAuth: { args in
                recorder.added.append(args)
            }
        )
        flow.onAdded = {
            recorder.addedCount += 1
        }
        return flow
    }

    private static func proof(purpose: String) -> BittensorWalletProofInfo {
        BittensorWalletProofInfo(walletId: SdkBittensorWalletTalisman, purpose: purpose, address: alice, message: message, signature: signature)
    }

    private func assertTaoWalletAuth(_ args: SdkAddAuthArgs?, file: StaticString = #filePath, line: UInt = #line) {
        guard let args else {
            XCTFail("no AddAuth request", file: file, line: line)
            return
        }
        XCTAssertTrue(addAuthArgsSupplyMethod(args), file: file, line: line)
        XCTAssertEqual(args.walletAuth?.blockchain, SdkTAO, file: file, line: line)
        XCTAssertEqual(args.walletAuth?.publicKey, Self.alice, file: file, line: line)
        XCTAssertEqual(args.walletAuth?.message, Self.message, file: file, line: line)
        XCTAssertEqual(args.walletAuth?.signature, Self.signature, file: file, line: line)
        // a wallet, never an sso token or a password
        XCTAssertEqual(args.authJwt, "", file: file, line: line)
        XCTAssertEqual(args.userAuth, "", file: file, line: line)
    }

    // MARK: - the options

    func testWalletOffersSolanaAndBittensor() {
        XCTAssertEqual(addAuthWalletChains, [.solana, .bittensor])
        XCTAssertEqual(addAuthSheetMethods(appleAvailable: true, googleAvailable: true), [.apple, .google, .wallet, .email])
    }

    // the login screen's flows: native where configured (iOS, the macOS App
    // Store build), the browser in the direct-download build
    func testAppleAndGoogleFollowTheLoginFlows() {
        XCTAssertEqual(addAuthProviderFlow(nativeConfigured: true, browserAvailable: false), .native)
        XCTAssertEqual(addAuthProviderFlow(nativeConfigured: false, browserAvailable: true), .browser)
        XCTAssertEqual(addAuthProviderFlow(nativeConfigured: false, browserAvailable: false), .unavailable)
    }

    // MARK: - Bittensor AddAuth request

    func testAnAddProofBecomesATaoWalletAuth() {
        assertTaoWalletAuth(addAuthBittensorArgs(Self.proof(purpose: SdkBittensorWalletPurposeAdd)))
    }

    func testOtherFlowsProofsAreNeverAdded() {
        for purpose in [SdkBittensorWalletPurposeLogin, SdkBittensorWalletPurposeCreate, SdkBittensorWalletPurposeConnect] {
            XCTAssertNil(addBittensorArgsOrNil(purpose), purpose)
        }
    }

    private func addBittensorArgsOrNil(_ purpose: String) -> SdkAddAuthArgs? {
        addAuthBittensorArgs(Self.proof(purpose: purpose))
    }

    // MARK: - the flow

    // macOS Talisman: the bridge in the browser, back on the redirect link
    func testBridgeAddsOnlyTheAddReturn() async {
        let recorder = Recorder()
        let flow = Self.flow(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)

        await flow.choose(walletId: SdkBittensorWalletTalisman)
        XCTAssertEqual(recorder.challengeArgs.count, 1)
        XCTAssertEqual(recorder.challengeArgs.first?.blockchain, SdkTAO)
        XCTAssertEqual(recorder.challengeArgs.first?.purpose, SdkBittensorWalletPurposeAdd)
        XCTAssertEqual(recorder.opened.count, 1)
        let opened = recorder.opened.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(opened?.queryItems?.first(where: { $0.name == "purpose" })?.value, SdkBittensorWalletPurposeAdd)
        XCTAssertEqual(flow.connector.stage, .awaitingBrowser(walletId: SdkBittensorWalletTalisman))

        // a sign-in hand-back is the login screen's: not added
        _ = await flow.handleOpenUrl(Self.returnUrl(purpose: SdkBittensorWalletPurposeLogin))
        XCTAssertTrue(recorder.added.isEmpty)
        XCTAssertEqual(flow.connector.stage, .awaitingBrowser(walletId: SdkBittensorWalletTalisman))

        let handled = await flow.handleOpenUrl(Self.returnUrl(purpose: SdkBittensorWalletPurposeAdd))
        XCTAssertTrue(handled)
        XCTAssertEqual(recorder.added.count, 1)
        assertTaoWalletAuth(recorder.added.first)
        XCTAssertEqual(recorder.addedCount, 1)

        // a replay adds nothing more
        _ = await flow.handleOpenUrl(Self.returnUrl(purpose: SdkBittensorWalletPurposeAdd))
        XCTAssertEqual(recorder.added.count, 1)
    }

    // the login screen's session never takes an add hand-back
    func testLoginSessionIgnoresAnAddReturn() async {
        let recorder = Recorder()
        let login = Self.connector(platform: SdkBittensorWalletPlatformMacos, recorder: recorder)
        var proofs: [BittensorWalletProofInfo] = []
        login.onProof = { proof in
            proofs.append(proof)
        }
        await login.choose(walletId: SdkBittensorWalletTalisman, purpose: SdkBittensorWalletPurposeLogin)

        await login.handleBridgeReturn(Self.returnUrl(purpose: SdkBittensorWalletPurposeAdd))
        XCTAssertTrue(proofs.isEmpty)
        XCTAssertEqual(login.stage, .awaitingBrowser(walletId: SdkBittensorWalletTalisman))
    }

    // iOS (and TAO.com everywhere): the pasted signature, through the api.
    // The only calls are the challenge and AddAuth: nothing signs in, nothing
    // returns a jwt to install.
    func testManualAddCallsOnlyTheChallengeAndAddAuth() async {
        let api = FakeApi()
        let flow = AddAuthBittensorFlow(
            connector: BittensorWalletConnector(
                platform: SdkBittensorWalletPlatformIos,
                fetchChallenge: { args in
                    try await api.authWalletChallenge(args)
                },
                now: { Self.nowMillis }
            ),
            addAuth: { args in
                _ = try await api.addAuth(args)
            }
        )
        var addedCount = 0
        flow.onAdded = {
            addedCount += 1
        }

        await flow.choose(walletId: SdkBittensorWalletTaoCom)
        XCTAssertEqual(flow.connector.stage, .manualSignature(walletId: SdkBittensorWalletTaoCom, message: Self.message))
        XCTAssertEqual(api.challengeArgs.first?.purpose, SdkBittensorWalletPurposeAdd)

        flow.connector.manualAddress = Self.alice
        flow.connector.manualSignature = Self.signature
        await flow.connector.submitManual()

        XCTAssertEqual(api.added.count, 1)
        assertTaoWalletAuth(api.added.first)
        XCTAssertEqual(addedCount, 1)
        XCTAssertEqual(api.signInCalls, [])
        XCTAssertFalse(flow.isAdding)
        XCTAssertNil(flow.addError)
    }

    func testTheSheetFlowUsesTheApi() async {
        let api = FakeApi()
        let flow = AddAuthBittensorFlow(api: api)
        await flow.choose(walletId: SdkBittensorWalletTaoCom)
        XCTAssertEqual(api.challengeArgs.count, 1)
        XCTAssertEqual(api.challengeArgs.first?.purpose, SdkBittensorWalletPurposeAdd)
        XCTAssertEqual(api.signInCalls, [])
        flow.cancel()
    }
}
