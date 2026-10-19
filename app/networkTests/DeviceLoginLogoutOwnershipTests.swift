import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

/// Holds actual manager completions until the test explicitly admits a batch.
private final class LoginLogoutDispatcher: @unchecked Sendable {
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

private final class LoginLogoutCommit: NSObject, SdkCommitCallbackProtocol {
    let completion: (Bool) -> Void
    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }
    func complete(_ success: Bool) { completion(success) }
}

@MainActor
private final class LoginLogoutFixture {
    let directory: URL
    let spaceManager: SdkNetworkSpaceManager
    let originalSpace: SdkNetworkSpace
    let replacementSpace: SdkNetworkSpace
    let original: SdkLocalState
    let replacement: SdkLocalState
    let dispatcher = LoginLogoutDispatcher()
    var manager: DeviceManager!
    var requests: [SdkAuthNetworkClientCallbackProtocol] = []
    var profileCompletions: [(Error?) -> Void] = []
    var localWork: [(SdkAsyncLocalState, SdkCommitCallbackProtocol)] = []
    var initialized: [String] = []
    var tunnelClears = 0

    init() throws {
        _ = SdkSetExtenderNetworkClientEnabled(false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("login-logout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spaceManager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "https://api.login-logout.example"
        values.platformUrl = "wss://connect.login-logout.example"
        originalSpace = try XCTUnwrap(spaceManager.updateNetworkSpaceValues(SdkNewNetworkSpaceKey("original.login-logout.example", "test"), values: values))
        replacementSpace = try XCTUnwrap(spaceManager.updateNetworkSpaceValues(SdkNewNetworkSpaceKey("replacement.login-logout.example", "test"), values: values))
        original = try XCTUnwrap(originalSpace.getAsyncLocalState()?.getLocalState())
        replacement = try XCTUnwrap(replacementSpace.getAsyncLocalState()?.getLocalState())
        manager = DeviceManager(
            startupMode: .production,
            automaticallyInitialize: false,
            authCallbackDispatch: { [dispatcher] in dispatcher.enqueue($0) },
            logoutEffects: DeviceLogoutEffects(
                clearTunnelCredential: { [unowned self] in self.tunnelClears += 1 },
                removeProfiles: { [unowned self] _, completion in self.profileCompletions.append(completion) },
                clearLocalState: { [unowned self] state, callback in self.localWork.append((state, callback)) }
            )
        )
        manager.setActiveNetworkSpace(originalSpace)
        try original.setRouteLocal(true)
    }

    func close() {
        manager.clearDevice()
        spaceManager.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func beginLogin(_ jwt: String, newNetwork: Bool = false, constructionSucceeds: Bool = true) async -> Task<Result<Void, Error>, Never> {
        let requested = XCTestExpectation(description: "request captured before replacement")
        let task = Task { @MainActor in
            await manager.authenticateNetworkClient(
                jwt,
                newNetwork: newNetwork,
                requestClient: { [self] api, _, callback in
                    XCTAssertEqual(api.getByJwt(), jwt)
                    requests.append(callback)
                    requested.fulfill()
                },
                initializeDevice: { [self] client, _ in
                    initialized.append(client)
                    return constructionSucceeds
                }
            )
        }
        let wait = await XCTWaiter.fulfillment(of: [requested], timeout: 5)
        XCTAssertEqual(wait, .completed)
        return task
    }

    func succeed(_ index: Int, client: String) {
        let result = SdkAuthNetworkClientResult()
        result.byClientJwt = client
        requests[index].result(result, err: nil)
    }

    func fail(_ index: Int) {
        requests[index].result(nil, err: NSError(domain: "synthetic-registration", code: 1))
    }

    func completeProfiles(_ error: Error? = nil, index: Int = 0) {
        profileCompletions[index](error)
        dispatcher.deliver()
    }

    /// Executes the real generated SDK async logout, then holds its manager finalizer.
    func runLocalLogout(_ index: Int = 0, deliverFinalizer: Bool = true) async {
        let finished = XCTestExpectation(description: "actual SDK logout completed")
        let (state, callback) = localWork[index]
        state.logout(LoginLogoutCommit { success in
            XCTAssertTrue(success)
            callback.complete(success)
            finished.fulfill()
        })
        let wait = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(wait, .completed)
        if deliverFinalizer { dispatcher.deliver() }
    }

    func assertLoginRejected(file: StaticString = #filePath, line: UInt = #line) async {
        let result = await manager.authenticateNetworkClient("synthetic-blocked-admin", requestClient: { _, _, _ in
            XCTFail("logout admitted a new registration", file: file, line: line)
        }, initializeDevice: { _, _ in XCTFail("logout admitted construction", file: file, line: line); return true })
        if case .success = result { XCTFail("logout admitted a login", file: file, line: line) }
        var committed = false
        XCTAssertFalse(manager.acceptNetworkLogin { committed = true }, file: file, line: line)
        XCTAssertFalse(committed, file: file, line: line)
        XCTAssertFalse(manager.initDevice(clientJwt: "synthetic-blocked-client", deviceSpec: "test"), file: file, line: line)
        var startup = 0
        manager.scheduleNetworkSpaceInitialization(dispatch: { $0() }, prepare: { _ in startup += 1 })
        XCTAssertEqual(startup, 0, file: file, line: line)
        manager.initializeStoredAuthentication(initializeDevice: { _, _ in startup += 1; return true })
        XCTAssertEqual(startup, 0, file: file, line: line)
    }
}

@MainActor
final class DeviceLoginLogoutOwnershipTests: XCTestCase {
    func testOldFailureCannotRollbackNewerLogin() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let old = await f.beginLogin("synthetic-old-admin")
        let current = await f.beginLogin("synthetic-current-admin")
        f.succeed(1, client: "synthetic-current-client")
        if case .failure = await current.value { XCTFail("current login failed") }
        f.fail(0)
        if case .success = await old.value { XCTFail("failed old request succeeded") }
        XCTAssertEqual(f.original.getByJwt(), "synthetic-current-admin")
        XCTAssertEqual(f.original.getByClientJwt(), "synthetic-current-client")
        XCTAssertEqual(f.manager.api?.getByJwt(), "synthetic-current-admin")
        XCTAssertEqual(f.initialized, ["synthetic-current-client"])
    }

    func testEqualAdminBytesStillRetireOldSuccess() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let old = await f.beginLogin("synthetic-equal-admin")
        let current = await f.beginLogin("synthetic-equal-admin")
        f.succeed(1, client: "synthetic-current-client")
        _ = await current.value
        f.succeed(0, client: "synthetic-stale-client")
        if case .success = await old.value { XCTFail("retired login succeeded") }
        XCTAssertEqual(f.original.getByClientJwt(), "synthetic-current-client")
        XCTAssertEqual(f.initialized, ["synthetic-current-client"])
    }

    func testSpaceReplacementRejectsOldSuccessBeforeStoreOrConstruction() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let old = await f.beginLogin("synthetic-old-admin")
        f.manager.setActiveNetworkSpace(f.replacementSpace)
        try f.replacement.setByJwt("synthetic-replacement-admin")
        try f.replacement.setByClientJwt("synthetic-replacement-client")
        f.manager.api?.setByJwt("synthetic-replacement-admin")
        f.succeed(0, client: "synthetic-stale-client")
        if case .success = await old.value { XCTFail("old space succeeded") }
        XCTAssertEqual(f.original.getByClientJwt(), "")
        XCTAssertEqual(f.replacement.getByClientJwt(), "synthetic-replacement-client")
        XCTAssertEqual(f.manager.api?.getByJwt(), "synthetic-replacement-admin")
        XCTAssertEqual(f.initialized, [])
    }

    func testSpaceReplacementRejectsOldFailureRollback() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let old = await f.beginLogin("synthetic-old-admin")
        f.manager.setActiveNetworkSpace(f.replacementSpace)
        try f.replacement.setByJwt("synthetic-replacement-admin")
        f.manager.api?.setByJwt("synthetic-replacement-admin")
        f.fail(0)
        _ = await old.value
        XCTAssertEqual(f.replacement.getByJwt(), "synthetic-replacement-admin")
        XCTAssertEqual(f.original.getByJwt(), "synthetic-old-admin")
        XCTAssertEqual(f.manager.api?.getByJwt(), "synthetic-replacement-admin")
    }

    func testQueuedResultCannotPublishAfterAcceptedLogin() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let old = await f.beginLogin("synthetic-old-admin")
        f.succeed(0, client: "synthetic-queued-client")
        try f.manager.acceptNetworkLogin { try f.original.setByJwt("synthetic-explicit-admin") }
        _ = await old.value
        XCTAssertEqual(f.original.getByJwt(), "synthetic-explicit-admin")
        XCTAssertEqual(f.original.getByClientJwt(), "")
        XCTAssertTrue(f.initialized.isEmpty)
    }

    func testCurrentFailureStillRollsBackAuthWithoutErasingSettings() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-current-admin")
        f.fail(0)
        _ = await task.value
        XCTAssertTrue(try f.original.getAuthStateSnapshot().getEmpty())
        XCTAssertEqual(f.manager.api?.getByJwt(), "")
        XCTAssertTrue(f.original.getRouteLocal())
    }

    func testCurrentSuccessPersistsCreatedAccountClassification() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-created-admin", newNetwork: true)
        f.succeed(0, client: "synthetic-created-client")
        if case .failure = await task.value { XCTFail("current login failed") }
        XCTAssertEqual(f.original.getByJwt(), "synthetic-created-admin")
        XCTAssertEqual(f.original.getByClientJwt(), "synthetic-created-client")
        XCTAssertTrue(f.original.getCanPromptIntroFunnel())
        XCTAssertEqual(f.initialized, ["synthetic-created-client"])
    }

    func testCurrentConstructionFailureStillRollsBack() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-admin", constructionSucceeds: false)
        f.succeed(0, client: "synthetic-client")
        if case .success = await task.value { XCTFail("construction failure succeeded") }
        XCTAssertTrue(try f.original.getAuthStateSnapshot().getEmpty())
        XCTAssertEqual(f.manager.api?.getByJwt(), "")
    }

    func testDuplicateRegistrationDeliveryPublishesOnlyOnce() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-admin")
        f.succeed(0, client: "synthetic-client")
        f.fail(0)
        f.succeed(0, client: "synthetic-duplicate-client")
        if case .failure = await task.value { XCTFail("first success was lost") }
        let drained = XCTestExpectation(description: "duplicate callback queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        let wait = await XCTWaiter.fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(wait, .completed)
        XCTAssertEqual(f.original.getByClientJwt(), "synthetic-client")
        XCTAssertEqual(f.initialized, ["synthetic-client"])
    }

    func testQuitRetiresPendingRegistration() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let task = await f.beginLogin("synthetic-admin")
        f.manager.closeOnQuit { _ in }
        f.succeed(0, client: "synthetic-client")
        _ = await task.value
        XCTAssertEqual(f.original.getByClientJwt(), "")
        XCTAssertTrue(f.initialized.isEmpty)
    }

    func testLogoutKeepsOriginalStoreAfterSpaceReplacement() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        try f.original.setByJwt("synthetic-original-admin")
        f.manager.api?.setByJwt("synthetic-original-admin")
        f.manager.logout()
        XCTAssertEqual(f.originalSpace.getApi()?.getByJwt(), "")
        f.manager.setActiveNetworkSpace(f.replacementSpace)
        try f.replacement.setByJwt("synthetic-replacement-admin")
        try f.replacement.setByClientJwt("synthetic-replacement-client")
        f.completeProfiles()
        XCTAssertEqual(f.localWork.count, 1)
        await f.runLocalLogout()
        XCTAssertTrue(try f.original.getAuthStateSnapshot().getEmpty())
        XCTAssertEqual(f.replacement.getByJwt(), "synthetic-replacement-admin")
        XCTAssertEqual(f.replacement.getByClientJwt(), "synthetic-replacement-client")
    }

    func testLogoutExcludesAdmissionThroughFinalCallback() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        try f.original.setByJwt("synthetic-original-admin")
        f.manager.logout()
        await f.assertLoginRejected()
        f.completeProfiles()
        await f.assertLoginRejected()
        await f.runLocalLogout(deliverFinalizer: false)
        await f.assertLoginRejected()
        XCTAssertEqual(f.dispatcher.deliver(), 1)
        let current = await f.beginLogin("synthetic-new-admin")
        f.succeed(0, client: "synthetic-new-client")
        if case .failure = await current.value { XCTFail("completed logout blocked login") }
        XCTAssertEqual(f.original.getByClientJwt(), "synthetic-new-client")
    }

    func testLogoutRetiresPendingLoginEvenAfterCleanupFinishes() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        let old = await f.beginLogin("synthetic-old-admin")
        f.manager.logout()
        f.completeProfiles()
        await f.runLocalLogout()
        f.succeed(0, client: "synthetic-stale-client")
        _ = await old.value
        XCTAssertTrue(try f.original.getAuthStateSnapshot().getEmpty())
        XCTAssertTrue(f.initialized.isEmpty)
    }

    func testLogoutRejectsAdminCommitUntilLocalCompletion() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        f.manager.logout()
        var commits = 0
        XCTAssertFalse(f.manager.acceptNetworkLogin { commits += 1 })
        f.completeProfiles()
        XCTAssertFalse(f.manager.acceptNetworkLogin { commits += 1 })
        await f.runLocalLogout(deliverFinalizer: false)
        XCTAssertFalse(f.manager.acceptNetworkLogin { commits += 1 })
        XCTAssertEqual(commits, 0)
        f.dispatcher.deliver()
        XCTAssertTrue(f.manager.acceptNetworkLogin { commits += 1 })
        XCTAssertEqual(commits, 1)
    }

    func testTimeoutCannotReopenAdminCommitAfterLocalCompletion() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        f.manager.logout()
        f.completeProfiles(VPNOperationTimeoutError(operation: "synthetic-profile", timeout: 2))
        await f.runLocalLogout()
        var commits = 0
        XCTAssertFalse(f.manager.acceptNetworkLogin { commits += 1 })
        XCTAssertEqual(commits, 0)
    }

    func testDuplicateProfileAndLocalCompletionsCannotClearRelogin() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        f.manager.logout()
        f.manager.logout()
        XCTAssertEqual(f.profileCompletions.count, 1)
        f.completeProfiles()
        f.completeProfiles()
        XCTAssertEqual(f.localWork.count, 1)
        await f.runLocalLogout()
        let current = await f.beginLogin("synthetic-new-admin")
        f.succeed(0, client: "synthetic-new-client")
        _ = await current.value
        f.localWork[0].1.complete(true)
        f.completeProfiles()
        f.dispatcher.deliver()
        XCTAssertEqual(f.original.getByJwt(), "synthetic-new-admin")
        XCTAssertEqual(f.original.getByClientJwt(), "synthetic-new-client")
        XCTAssertEqual(f.localWork.count, 1)
    }

    func testProfileTimeoutKeepsAdmissionClosedAfterLocalCompletion() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        try f.original.setByJwt("synthetic-original-admin")
        f.manager.logout()
        f.completeProfiles(VPNOperationTimeoutError(operation: "synthetic-logout", timeout: 2))
        await f.runLocalLogout()
        XCTAssertTrue(try f.original.getAuthStateSnapshot().getEmpty())
        await f.assertLoginRejected()
        f.completeProfiles() // a late duplicate cannot convert a deadline into a join
        await f.assertLoginRejected()
    }

    func testOldFinalCallbackCannotReleaseLaterLogout() async throws {
        let f = try LoginLogoutFixture(); defer { f.close() }
        f.manager.logout()
        f.completeProfiles()
        await f.runLocalLogout()
        f.manager.logout()
        XCTAssertEqual(f.profileCompletions.count, 2)
        f.localWork[0].1.complete(true)
        f.dispatcher.deliver()
        var committed = false
        XCTAssertFalse(f.manager.acceptNetworkLogin { committed = true })
        XCTAssertFalse(committed)
        guard !committed else { return }
        f.completeProfiles(index: 1)
        await f.runLocalLogout(1)
        XCTAssertTrue(f.manager.acceptNetworkLogin {})
    }

    func testCleanupRetainsProviderTimeoutWhenRemovalSucceeds() {
        var provider: ((Error?) -> Void)?
        var removal: ((Error?) -> Void)?
        var outcomes: [Error?] = []
        performVPNLogoutCleanup(notifyProviders: { provider = $0 }, removeProfiles: { removal = $0 }, completion: { outcomes.append($0) })
        provider?(VPNOperationTimeoutError(operation: "synthetic-provider", timeout: 2))
        XCTAssertTrue(outcomes.isEmpty)
        removal?(nil)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(outcomes[0] is VPNOperationTimeoutError)
        provider?(nil)
        removal?(nil)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testCleanupCurrentSuccessStillCompletes() {
        var outcomes: [Error?] = []
        performVPNLogoutCleanup(notifyProviders: { $0(nil) }, removeProfiles: { $0(nil) }, completion: { outcomes.append($0) })
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes[0])
    }

    func testCleanupRemovalFailureStillPropagates() {
        var outcome: Error?
        performVPNLogoutCleanup(notifyProviders: { $0(nil) }, removeProfiles: { $0(VPNOperationTimeoutError(operation: "synthetic-removal", timeout: 2)) }, completion: { outcome = $0 })
        XCTAssertTrue(outcome is VPNOperationTimeoutError)
    }
}
