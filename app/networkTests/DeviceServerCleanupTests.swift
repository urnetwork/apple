import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

// Sign-out used to clear only local state: the device's client stayed active
// and its session valid, and a sign-in abandoned after the server created its
// client left that client behind. Each counted toward the network's active
// top-level clients until the idle reap. These pin that the server half runs
// while the network credential is installed, and that it is bounded.

/// Holds manager completions until the test admits a batch.
private final class ServerCleanupDispatcher: @unchecked Sendable {
    private let stateLock = NSLock()
    private var work: [DeviceAuthCallbackWork] = []

    func enqueue(_ callback: @escaping DeviceAuthCallbackWork) {
        stateLock.lock()
        work.append(callback)
        stateLock.unlock()
    }

    @MainActor @discardableResult
    func deliver() -> Int {
        stateLock.lock()
        let batch = work
        work.removeAll()
        stateLock.unlock()
        batch.forEach { $0() }
        return batch.count
    }
}

@MainActor
private final class ServerCleanupFixture {
    let directory: URL
    let spaceManager: SdkNetworkSpaceManager
    let space: SdkNetworkSpace
    let localState: SdkLocalState
    let dispatcher = ServerCleanupDispatcher()
    var manager: DeviceManager!
    var requests: [SdkAuthNetworkClientCallbackProtocol] = []
    var profileCompletions: [(Error?) -> Void] = []
    // the credential the API held when each server effect started
    var signOuts: [(credential: String, profilesBefore: Int, completion: () -> Void)] = []
    var removals: [(clientId: String, credential: String)] = []

    init() throws {
        _ = SdkSetExtenderNetworkClientEnabled(false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("server-cleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spaceManager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "https://api.server-cleanup.example"
        values.platformUrl = "wss://connect.server-cleanup.example"
        space = try XCTUnwrap(spaceManager.updateNetworkSpaceValues(SdkNewNetworkSpaceKey("server-cleanup.example", "test"), values: values))
        localState = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
        var effects = DeviceLogoutEffects(
            clearTunnelCredential: {},
            removeProfiles: { [unowned self] _, completion in self.profileCompletions.append(completion) },
            clearLocalState: { _, callback in callback.complete(true) }
        )
        effects.signOutSession = { [unowned self] api, _, completion in
            self.signOuts.append((api?.getByJwt() ?? "", self.profileCompletions.count, completion))
            return true
        }
        effects.removeAbandonedClient = { [unowned self] api, clientId, _, completion in
            self.removals.append((clientId.string(), api.getByJwt()))
            completion()
            return true
        }
        manager = DeviceManager(
            startupMode: .production,
            automaticallyInitialize: false,
            authCallbackDispatch: { [dispatcher] in dispatcher.enqueue($0) },
            logoutEffects: effects
        )
        manager.setActiveNetworkSpace(space)
    }

    func close() {
        manager.clearDevice()
        spaceManager.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func beginLogin(_ jwt: String, constructionSucceeds: Bool) async -> Task<Result<Void, Error>, Never> {
        let requested = XCTestExpectation(description: "request captured")
        let task = Task { @MainActor in
            await manager.authenticateNetworkClient(
                jwt,
                requestClient: { [self] _, _, callback in
                    requests.append(callback)
                    requested.fulfill()
                },
                initializeDevice: { _, _ in constructionSucceeds }
            )
        }
        let wait = await XCTWaiter.fulfillment(of: [requested], timeout: 5)
        XCTAssertEqual(wait, .completed)
        return task
    }

    func succeed(_ index: Int, client: String, clientId: SdkId?) {
        let result = SdkAuthNetworkClientResult()
        result.byClientJwt = client
        result.clientId = clientId
        requests[index].result(result, err: nil)
    }
}

@MainActor
final class DeviceServerCleanupTests: XCTestCase {
    func testLogoutSignsOutOnTheServerBeforeClearingTheCredential() throws {
        let f = try ServerCleanupFixture(); defer { f.close() }
        try f.localState.setByJwt("synthetic-admin")
        f.manager.api?.setByJwt("synthetic-admin")

        f.manager.logout()
        // the server half starts first, with the network credential installed
        XCTAssertEqual(f.signOuts.count, 1)
        XCTAssertEqual(f.signOuts.first?.credential, "synthetic-admin")
        XCTAssertEqual(f.signOuts.first?.profilesBefore, 0)
        XCTAssertEqual(f.manager.api?.getByJwt(), "synthetic-admin")
        XCTAssertTrue(f.profileCompletions.isEmpty)

        // the local half follows its answer
        f.signOuts[0].completion()
        XCTAssertEqual(f.dispatcher.deliver(), 1)
        XCTAssertEqual(f.manager.api?.getByJwt(), "")
        XCTAssertEqual(f.profileCompletions.count, 1)

        // a second answer (the bound after the sdk's) starts nothing again
        f.signOuts[0].completion()
        f.dispatcher.deliver()
        XCTAssertEqual(f.profileCompletions.count, 1)
    }

    func testServerCleanupCallbackAnswersOnceByTheBound() async {
        let bound = XCTestExpectation(description: "the bound answers")
        var answers = 0
        let callback = ServerCleanupCallback(bound: 0.05) {
            answers += 1
            bound.fulfill()
        }
        let wait = await XCTWaiter.fulfillment(of: [bound], timeout: 5)
        XCTAssertEqual(wait, .completed)

        // the sdk's late answer is dropped
        callback.result(nil, p1: nil)
        let drained = XCTestExpectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        _ = await XCTWaiter.fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(answers, 1)
    }

    func testAbandonedSignInRemovesItsClientBeforeTheRollback() async throws {
        let f = try ServerCleanupFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-admin", constructionSucceeds: false)
        let clientId = try XCTUnwrap(SdkNewId())
        f.succeed(0, client: "synthetic-client", clientId: clientId)
        if case .success = await task.value { XCTFail("construction failure succeeded") }

        XCTAssertEqual(f.removals.count, 1)
        XCTAssertEqual(f.removals.first?.clientId, clientId.string())
        // removed with the network credential, before the rollback cleared it
        XCTAssertEqual(f.removals.first?.credential, "synthetic-admin")
        XCTAssertEqual(f.manager.api?.getByJwt(), "")
    }

    func testCommittedSignInRemovesNothing() async throws {
        let f = try ServerCleanupFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-admin", constructionSucceeds: true)
        f.succeed(0, client: "synthetic-client", clientId: try XCTUnwrap(SdkNewId()))
        if case .failure = await task.value { XCTFail("committed sign-in failed") }
        XCTAssertTrue(f.removals.isEmpty)
    }
}
