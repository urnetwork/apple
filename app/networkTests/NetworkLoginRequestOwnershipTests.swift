import CryptoKit
import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

@MainActor
final class OuterLoginFixture {
    let directory: URL
    let spaces: SdkNetworkSpaceManager
    let space: SdkNetworkSpace
    let other: SdkNetworkSpace
    let state: SdkLocalState
    let manager: DeviceManager
    var registrations = 0
    var acceptedUI = 0
    var initialized: [String] = []

    init() throws {
        _ = SdkSetExtenderNetworkClientEnabled(false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("outer-login-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spaces = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "https://api.outer-login.example"
        values.platformUrl = "wss://connect.outer-login.example"
        space = try XCTUnwrap(spaces.updateNetworkSpaceValues(SdkNewNetworkSpaceKey("original.outer-login.example", "test"), values: values))
        other = try XCTUnwrap(spaces.updateNetworkSpaceValues(SdkNewNetworkSpaceKey("other.outer-login.example", "test"), values: values))
        state = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
        manager = DeviceManager(startupMode: .production, automaticallyInitialize: false)
        manager.setActiveNetworkSpace(space)
    }

    func close() {
        manager.clearDevice()
        spaces.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func begin() throws -> NetworkLoginRequest {
        try XCTUnwrap(NetworkLoginContext(manager: manager, origin: manager.networkLoginOrigin).begin())
    }

    func register(_ request: NetworkLoginRequest, jwt: String = "synthetic-admin", created: Bool = false) async -> Result<Void, Error> {
        await manager.authenticateNetworkClient(
            NetworkLogin(jwt: jwt, newNetwork: created), request: request,
            requestClient: { [self] api, _, callback in
                registrations += 1
                XCTAssertEqual(api.getByJwt(), jwt)
                let result = SdkAuthNetworkClientResult()
                result.byClientJwt = "synthetic-client-" + jwt
                callback.result(result, err: nil)
            },
            initializeDevice: { [self] client, _ in initialized.append(client); return true },
            accepted: { [self] in acceptedUI += 1 }
        )
    }
}

@MainActor
final class OuterHeldResult<Value> {
    let started = XCTestExpectation(description: "producer is suspended")
    private var continuation: CheckedContinuation<Value, Error>?
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func reach() async { let result = await XCTWaiter.fulfillment(of: [started], timeout: 5); XCTAssertEqual(result, .completed) }
    func finish(_ result: Result<Value, Error>) {
        let pending = continuation
        continuation = nil
        XCTAssertNotNil(pending)
        pending?.resume(with: result)
    }
}

@MainActor
final class NetworkLoginRequestOwnershipTests: XCTestCase {
    func testLateOuterResultCannotInstallAdminAfterReplacementEvenWithEqualJwt() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let old = try f.begin()
        let current = try f.begin()
        if case .failure = await f.register(current) { XCTFail("current login rejected") }
        if case .success = await f.register(old) { XCTFail("retired producer accepted") }
        XCTAssertEqual(f.registrations, 1)
        XCTAssertEqual(f.acceptedUI, 1)
        XCTAssertEqual(f.initialized, ["synthetic-client-synthetic-admin"])
        XCTAssertEqual(f.state.getByJwt(), "synthetic-admin")
        XCTAssertEqual(f.state.getByClientJwt(), "synthetic-client-synthetic-admin")
    }

    func testRetiredDisplayedFlowCannotMintRequestAfterSameSpaceReassignment() throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let context = NetworkLoginContext(manager: f.manager, origin: f.manager.networkLoginOrigin)
        let old = try XCTUnwrap(context.begin())
        f.manager.setActiveNetworkSpace(f.space)
        XCTAssertFalse(old.isCurrent)
        XCTAssertNil(context.begin())
        XCTAssertTrue(try f.begin().isCurrent)
    }

    func testOldSpaceResultCannotInstallInNewSpace() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let old = try f.begin()
        f.manager.setActiveNetworkSpace(f.other)
        if case .success = await f.register(old) { XCTFail("old space accepted") }
        XCTAssertEqual(f.registrations, 0)
        XCTAssertEqual(f.acceptedUI, 0)
        XCTAssertTrue(try f.state.getAuthStateSnapshot().getEmpty())
        XCTAssertTrue(try XCTUnwrap(f.other.getAsyncLocalState()?.getLocalState()).getAuthStateSnapshot().getEmpty())
    }

    func testPendingAttemptKeepsAcceptedLoginAndItsPublicationCurrent() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let serving = try f.begin()
        if case .failure = await f.register(serving) { XCTFail("serving login rejected") }
        let pending = try f.begin()
        XCTAssertTrue(serving.isCurrent)
        XCTAssertTrue(pending.isCurrent)
        var publications = 0
        XCTAssertTrue(serving.publish { publications += 1 })
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(f.state.getByJwt(), "synthetic-admin")
        XCTAssertEqual(f.state.getByClientJwt(), "synthetic-client-synthetic-admin")
    }

    func testAcceptedRequestCannotRegisterTwiceAndKeepsCreateClassification() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let request = try f.begin()
        if case .failure = await f.register(request, created: true) { XCTFail("created login rejected") }
        if case .success = await f.register(request, created: false) { XCTFail("duplicate login accepted") }
        XCTAssertEqual(f.registrations, 1)
        XCTAssertEqual(f.acceptedUI, 1)
        XCTAssertTrue(f.state.getCanPromptIntroFunnel())
    }

    func testQueuedProviderCompletionRetainsIngressRequestBeforeNewAttempt() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let old = try f.begin()
        var slot = NetworkLoginCallback<String>(request: old)
        var work: [@MainActor () async -> Void] = []
        var delivered: [String] = []
        XCTAssertTrue(slot.receive("old-provider-token", enqueue: { work.append($0) }) { token, request in
            delivered.append(token)
            _ = await f.register(request, jwt: token)
        })
        let current = try f.begin()
        slot = NetworkLoginCallback(request: current)
        await work.removeFirst()()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(f.registrations, 0)
        XCTAssertTrue(slot.receive("current-provider-token", enqueue: { work.append($0) }) { token, request in
            delivered.append(token)
            _ = await f.register(request, jwt: token)
        })
        XCTAssertFalse(slot.receive("duplicate", enqueue: { work.append($0) }) { _, _ in XCTFail("duplicate callback") })
        await work.removeFirst()()
        XCTAssertEqual(delivered, ["current-provider-token"])
        XCTAssertEqual(f.registrations, 1)
    }

    func testQueuedProviderFailureCannotPublishAfterSpaceChange() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let callback = NetworkLoginCallback<Error>(request: try f.begin())
        var work: [@MainActor () async -> Void] = []
        var errorPublications = 0
        callback.receive(NSError(domain: "synthetic", code: 1), enqueue: { work.append($0) }) { _, _ in errorPublications += 1 }
        f.manager.setActiveNetworkSpace(f.other)
        await work.removeFirst()()
        XCTAssertEqual(errorPublications, 0)
    }

    func testAcceptedOldRequestCannotPublishAfterLaterAcceptedLogin() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let old = try f.begin()
        _ = await f.register(old)
        let current = try f.begin()
        _ = await f.register(current)
        var count = 0
        XCTAssertFalse(old.publish { count += 1 })
        XCTAssertTrue(current.publish { count += 1 })
        XCTAssertEqual(count, 1)
    }

    func testSolanaSignatureProvesExactChallengeAndCurrentKey() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let publicKey = SdkEncodeBase58(key.publicKey.rawRepresentation)
        let oldMessage = "Sign in\nChallenge: old-synthetic"
        let currentMessage = "Sign in\nChallenge: current-synthetic"
        let oldSignature = try key.signature(for: Data(oldMessage.utf8)).base64EncodedString()
        let currentSignature = try key.signature(for: Data(currentMessage.utf8)).base64EncodedString()
        XCTAssertFalse(NetworkLoginWalletProof.matches(message: currentMessage, signature: oldSignature, publicKey: publicKey))
        XCTAssertTrue(NetworkLoginWalletProof.matches(message: currentMessage, signature: currentSignature, publicKey: publicKey))
        let otherKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))
        XCTAssertFalse(NetworkLoginWalletProof.matches(message: currentMessage, signature: currentSignature, publicKey: SdkEncodeBase58(otherKey.publicKey.rawRepresentation)))
        XCTAssertFalse(NetworkLoginWalletProof.matches(message: currentMessage, signature: "invalid", publicKey: publicKey))
    }

    private func connector(platform: String, proofs: @escaping (BittensorWalletProofInfo) -> Void) -> BittensorWalletConnector {
        let connector = BittensorWalletConnector(platform: platform, fetchChallenge: { _ in
            let result = SdkAuthWalletChallengeResult()
            result.messageTemplate = "Sign in to URnetwork\nChallenge: synthetic-outer-login\nTimestamp: 1757340000"
            result.expiresIn = 300
            return result
        }, openUrl: { _ in true }, now: { 1_757_340_000_000 })
        connector.onProof = { proof in proofs(proof) }
        return connector
    }

    func testQueuedBittensorBridgeReturnCannotTargetReplacementSession() async throws {
        var proofCount = 0
        let connector = connector(platform: SdkBittensorWalletPlatformMacos) { _ in proofCount += 1 }
        await connector.choose(walletId: SdkBittensorWalletTalisman, purpose: SdkBittensorWalletPurposeLogin)
        let url = try XCTUnwrap(URL(string: "urnetwork://bittensor-sign-message?purpose=login&errorCode=user_rejected&errorMessage=old"))
        let old = try XCTUnwrap(connector.captureBridgeReturn(url))
        await connector.choose(walletId: SdkBittensorWalletTalisman, purpose: SdkBittensorWalletPurposeLogin)
        let currentStage = connector.stage
        await old()
        XCTAssertEqual(connector.stage, currentStage)
        XCTAssertEqual(proofCount, 0)
        let current = try XCTUnwrap(connector.captureBridgeReturn(url))
        await current()
        guard case .failed = connector.stage else { return XCTFail("current wallet refusal lost") }
    }

    func testQueuedBittensorManualSubmissionCapturesSessionAndInput() async throws {
        var proofs: [BittensorWalletProofInfo] = []
        let connector = connector(platform: SdkBittensorWalletPlatformIos) { proofs.append($0) }
        await connector.choose(walletId: SdkBittensorWalletTaoCom, purpose: SdkBittensorWalletPurposeLogin)
        connector.manualAddress = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        connector.manualSignature = "0x" + String(repeating: "ab", count: 64)
        let old = try XCTUnwrap(connector.captureManualSubmission())
        await connector.choose(walletId: SdkBittensorWalletTaoCom, purpose: SdkBittensorWalletPurposeLogin)
        let currentStage = connector.stage
        await old()
        XCTAssertEqual(connector.stage, currentStage)
        XCTAssertTrue(proofs.isEmpty)
        connector.manualAddress = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
        connector.manualSignature = "0x" + String(repeating: "ab", count: 64)
        let current = try XCTUnwrap(connector.captureManualSubmission())
        connector.manualAddress = "edited after ingress"
        await current()
        XCTAssertEqual(proofs.count, 1)
        XCTAssertEqual(proofs.first?.address, "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY")
    }
    func testSolanaSignedCallbackUsesOriginalRequestAcrossQueueAndCurrentCompletes() async throws {
        let f = try OuterLoginFixture(); defer { f.close() }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 8, count: 32))
        let publicKey = SdkEncodeBase58(key.publicKey.rawRepresentation)
        let message = "synthetic-current-challenge"
        let signature = try key.signature(for: Data(message.utf8)).base64EncodedString()
        var work: [@MainActor () async -> Void] = []
        var delivered = 0
        let old = NetworkLoginWalletAttempt(request: try f.begin(), message: message)
        let oldURL = try XCTUnwrap(URL(string: NetworkLoginWalletAttempt.redirectLink("urnetwork://phantom-sign-message", attemptId: old.id) + "?data=synthetic"))
        XCTAssertTrue(old.receive(oldURL, signature: signature, publicKey: publicKey, enqueue: { work.append($0) }) { _, _, _, _ in delivered += 1 })
        let current = NetworkLoginWalletAttempt(request: try f.begin(), message: message)
        await work.removeFirst()()
        XCTAssertEqual(delivered, 0)
        XCTAssertFalse(current.receive(oldURL, signature: signature, publicKey: publicKey, enqueue: { work.append($0) }) { _, _, _, _ in delivered += 1 })
        let url = try XCTUnwrap(URL(string: NetworkLoginWalletAttempt.redirectLink("urnetwork://solflare-sign-message", attemptId: current.id) + "?data=synthetic"))
        XCTAssertTrue(current.receive(url, signature: signature, publicKey: publicKey, enqueue: { work.append($0) }) { _, _, _, request in
            _ = await f.register(request)
            delivered += 1
        })
        await work.removeFirst()()
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(f.registrations, 1)
    }

}
