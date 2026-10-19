import Combine
import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

/// A positive FIFO barrier drains real SDK writes and their queued main-actor completions.
private final class StartupReadBarrier: NSObject, SdkGetByJwtCallbackProtocol {
    let completion: () -> Void

    init(_ completion: @escaping () -> Void) { self.completion = completion }

    func result(_ result: String?, ok: Bool) {
        DispatchQueue.main.async(execute: completion)
    }
}

/// Delivers the SDK listener contract without a network response or a remote device.
private final class StartupLogoutSource: DeviceAuthCallbackSource {
    var logout: (@Sendable (String) -> Void)?
    func authCallbackInstanceId() -> String? { nil }
    func observeAuthRefresh(_ callback: @escaping @Sendable (String?) -> Void) -> () -> Void { {} }
    func observeAuthLogout(_ callback: @escaping @Sendable (String) -> Void) -> () -> Void {
        logout = callback
        return {}
    }
}

/// All state is generated here; no device/RPC, profile, Keychain or account is opened.
@MainActor
private final class StoredStartupFixture {
    let directory: URL
    let spaceManager: SdkNetworkSpaceManager
    let space: SdkNetworkSpace
    let localState: SdkLocalState
    let manager: DeviceManager
    let authFile: URL
    let settingFile: URL
    static let admin = "synthetic-startup-admin"
    static let client = "synthetic-startup-client"

    init(savedSession: Bool = true) throws {
        _ = SdkSetExtenderNetworkClientEnabled(false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stored-startup-" + UUID().uuidString, isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spaceManager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "https://api.startup.example"
        values.platformUrl = "wss://connect.startup.example"
        let key = try XCTUnwrap(SdkNewNetworkSpaceKey("startup.example", "test"))
        space = try XCTUnwrap(spaceManager.updateNetworkSpaceValues(key, values: values))
        localState = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
        manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        manager.setActiveNetworkSpace(space)
        let stateDirectory = directory.appendingPathComponent("network_spaces/startup.example/test/.by")
        authFile = stateDirectory.appendingPathComponent(".auth_state")
        settingFile = stateDirectory.appendingPathComponent("startup-setting-sentinel")
        if savedSession {
            try localState.setByJwt(Self.admin)
            try localState.setByClientJwt(Self.client)
            manager.api?.setByJwt(Self.admin)
        }
        try localState.setRouteLocal(true)
        try Data("synthetic-setting".utf8).write(to: settingFile)
    }

    func close() {
        manager.clearDevice()
        spaceManager.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func drainWrites() async {
        await withCheckedContinuation { continuation in
            space.getAsyncLocalState()?.getByJwt(StartupReadBarrier { continuation.resume() })
        }
    }

    /// A directory at the envelope path forces the SDK's checked filesystem read to fail.
    func withUnavailableAuth(_ work: () throws -> Void) throws {
        let bytes = try Data(contentsOf: authFile)
        try FileManager.default.removeItem(at: authFile)
        try FileManager.default.createDirectory(at: authFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try localState.getAuthStateSnapshot())
        var workError: Error?
        do { try work() } catch { workError = error }
        try FileManager.default.removeItem(at: authFile)
        try bytes.write(to: authFile)
        // Prove storage recovered before returning the failure to startup cleanup.
        XCTAssertEqual(try Data(contentsOf: authFile), bytes)
        XCTAssertEqual(try localState.getAuthStateSnapshot().getByClientJwt(), Self.client)
        if let workError { throw workError }
    }

    func assertSessionRetained(instanceId: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try localState.getAuthStateSnapshot()
        XCTAssertEqual(snapshot.getByJwt(), Self.admin, file: file, line: line)
        XCTAssertEqual(snapshot.getByClientJwt(), Self.client, file: file, line: line)
        XCTAssertEqual(snapshot.getInstanceId()?.string(), instanceId, file: file, line: line)
        XCTAssertEqual(manager.api?.getByJwt(), Self.admin, file: file, line: line)
        XCTAssertTrue(localState.getRouteLocal(), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: settingFile), Data("synthetic-setting".utf8), file: file, line: line)
    }
}

/// Exercises actual startup/constructor failure and auth ownership over the real SDK store.
@MainActor
final class DeviceStoredAuthenticationStartupTests: XCTestCase {
    func testTransientCheckedReadFailurePreservesSavedSessionAndSettings() async throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let instanceId = fixture.localState.getInstanceId()?.string()
        let savedAuth = try Data(contentsOf: fixture.authFile)
        var initializedValues: [Bool] = []
        let subscription = fixture.manager.$deviceInitialized.sink { initializedValues.append($0) }
        defer { subscription.cancel() }
        var failedConstructions = 0
        fixture.manager.initializeStoredAuthentication(initializeDevice: { clientJwt, spec in
            XCTAssertEqual(clientJwt, StoredStartupFixture.client)
            var initialized = true
            do {
                try fixture.withUnavailableAuth {
                    initialized = fixture.manager.initDevice(clientJwt: clientJwt, deviceSpec: spec)
                    XCTAssertFalse(initialized, "the real second checked auth read must fail")
                    failedConstructions += 1
                }
            } catch { XCTFail("failed to install the storage fault: \(error)") }
            return initialized
        })
        // Valid bytes have recovered before the failed result reaches the startup owner.
        await fixture.drainWrites()
        XCTAssertEqual(failedConstructions, 1)
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .retryableFailure)
        XCTAssertFalse(fixture.manager.deviceInitialized)
        XCTAssertFalse(initializedValues.contains(true), "unknown startup must never emit completion")
        try fixture.assertSessionRetained(instanceId: instanceId)
        XCTAssertEqual(try Data(contentsOf: fixture.authFile), savedAuth)
    }

    func testUnavailableFirstSnapshotRetriesWithoutPresentingSignIn() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let instanceId = fixture.localState.getInstanceId()?.string()
        var constructions = 0
        try fixture.withUnavailableAuth {
            fixture.manager.initializeStoredAuthentication(initializeDevice: { _, _ in
                constructions += 1
                return true
            })
        }
        XCTAssertEqual(constructions, 0)
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .retryableFailure)
        XCTAssertFalse(fixture.manager.deviceInitialized)
        let viewModel = ContentView.ViewModel()
        viewModel.updatePath(nil, startupState: fixture.manager.storedAuthenticationStartupState)
        XCTAssertEqual(viewModel.contentViewPath, .uninitialized)

        fixture.manager.initializeStoredAuthentication(initializeDevice: { clientJwt, _ in
            XCTAssertEqual(clientJwt, StoredStartupFixture.client)
            constructions += 1
            return true
        })
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .settled)
        try fixture.assertSessionRetained(instanceId: instanceId)
    }

    func testHealthyStartupPassesClientCredentialAndPreservesAdmin() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let instanceId = fixture.localState.getInstanceId()?.string()
        var constructions = 0
        fixture.manager.initializeStoredAuthentication(initializeDevice: { clientJwt, _ in
            XCTAssertEqual(clientJwt, StoredStartupFixture.client)
            constructions += 1
            return true
        })
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .settled)
        try fixture.assertSessionRetained(instanceId: instanceId)
    }

    func testCheckedEmptyStateEntersSignInWithoutDeletingSettings() throws {
        let fixture = try StoredStartupFixture(savedSession: false)
        defer { fixture.close() }
        fixture.manager.initializeStoredAuthentication(initializeDevice: { _, _ in
            XCTFail("empty auth cannot construct a device")
            return false
        })
        XCTAssertTrue(fixture.manager.deviceInitialized)
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .settled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.settingFile.path))
        let viewModel = ContentView.ViewModel()
        viewModel.updatePath(nil, startupState: fixture.manager.storedAuthenticationStartupState)
        XCTAssertEqual(viewModel.contentViewPath, .authenticate)
    }

    func testIncompleteSavedAuthIsRetryableAndPreserved() throws {
        let fixture = try StoredStartupFixture(savedSession: false)
        defer { fixture.close() }
        try fixture.localState.setByJwt(StoredStartupFixture.admin)
        fixture.manager.initializeStoredAuthentication(initializeDevice: { _, _ in
            XCTFail("incomplete auth cannot construct a device")
            return false
        })
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .retryableFailure)
        XCTAssertFalse(fixture.manager.deviceInitialized)
        XCTAssertEqual(fixture.localState.getByJwt(), StoredStartupFixture.admin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.settingFile.path))
    }

    func testUnavailableNetworkSpaceIsRetryable() {
        let manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        manager.initializeStoredAuthentication()
        XCTAssertEqual(manager.storedAuthenticationStartupState, .retryableFailure)
        XCTAssertFalse(manager.deviceInitialized)
    }

    func testQueuedSpaceRetryIsRetiredByLogout() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        fixture.manager.setActiveNetworkSpace(nil)
        fixture.manager.initializeStoredAuthentication()
        var pending: (@MainActor () -> Void)?
        fixture.manager.retryStoredAuthenticationStartup(
            dispatchPreparation: { pending = $0 },
            prepareNetworkSpace: { _ in XCTFail("logout retired queued space preparation") }
        )
        XCTAssertNotNil(pending)
        fixture.manager.logout()
        pending?()
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .settled)
    }

    func testQueuedSpaceRetryIsRetiredByAcceptedLogin() {
        let manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        manager.initializeStoredAuthentication()
        var pending: (@MainActor () -> Void)?
        manager.retryStoredAuthenticationStartup(
            dispatchPreparation: { pending = $0 },
            prepareNetworkSpace: { _ in XCTFail("accepted login retired queued space preparation") }
        )
        manager.acceptNetworkLogin {}
        pending?()
        XCTAssertEqual(manager.storedAuthenticationStartupState, .settled)
    }

    func testQueuedInitialPreparationIsRetiredBySpaceReplacement() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        var pending: (@MainActor () -> Void)?
        fixture.manager.scheduleNetworkSpaceInitialization(
            dispatch: { pending = $0 },
            prepare: { _ in XCTFail("space replacement retired initial preparation") }
        )
        fixture.manager.setActiveNetworkSpace(fixture.space)
        pending?()
        XCTAssertEqual(fixture.manager.storedAuthenticationStartupState, .settled)
    }

    func testQueuedPreparationExecutesOnlyOnce() {
        let manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        var pending: (@MainActor () -> Void)?
        var preparations = 0
        manager.scheduleNetworkSpaceInitialization(
            dispatch: { pending = $0 },
            prepare: { _ in preparations += 1 }
        )
        pending?()
        pending?()
        XCTAssertEqual(preparations, 1)
    }

    func testQueuedInitialPreparationIsRetiredByQuit() {
        let manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        var pending: (@MainActor () -> Void)?
        manager.scheduleNetworkSpaceInitialization(
            dispatch: { pending = $0 },
            prepare: { _ in XCTFail("quit retired queued space preparation") }
        )
        var quitCompleted = false
        manager.closeOnQuit { error in
            XCTAssertNil(error)
            quitCompleted = true
        }
        pending?()
        XCTAssertTrue(quitCompleted)
    }

    func testExplicitLogoutRetiresStartupAndStillDeletesAccountState() async throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        var completion: ((String?) -> Void)?
        fixture.manager.initializeStoredAuthentication(loadActiveInstanceId: { completion = $0 }, initializeDevice: { _, _ in
            XCTFail("retired startup cannot reconstruct the signed-out device")
            return true
        })
        fixture.manager.logout()
        completion?(SdkNewId()?.string())
        await fixture.drainWrites()
        XCTAssertTrue(try fixture.localState.getAuthStateSnapshot().getEmpty())
        XCTAssertEqual(fixture.manager.api?.getByJwt(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settingFile.path))
    }

    func testCurrentSdkLogoutCallbackStillDeletesAccountState() async throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let source = StartupLogoutSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.logout?(SdkAuthLogoutCauseSessionRevoked)
        // Queue the SDK barrier only after main-actor logout admission has run.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await fixture.drainWrites()
        XCTAssertTrue(try fixture.localState.getAuthStateSnapshot().getEmpty())
        XCTAssertEqual(fixture.manager.api?.getByJwt(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settingFile.path))
        XCTAssertEqual(fixture.manager.signedOutNotice, .signedOutRemotely)
    }

    func testAcceptedReplacementLoginRetiresStartupEvenWithEqualCredential() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let instanceId = fixture.localState.getInstanceId()?.string()
        var completion: ((String?) -> Void)?
        fixture.manager.initializeStoredAuthentication(loadActiveInstanceId: { completion = $0 }, initializeDevice: { _, _ in
            XCTFail("retired startup cannot publish after an accepted login")
            return true
        })
        try fixture.manager.acceptNetworkLogin { try fixture.localState.setByJwt(StoredStartupFixture.admin) }
        completion?(SdkNewId()?.string())
        try fixture.assertSessionRetained(instanceId: instanceId)
    }

    func testSpaceReplacementRetiresStartupEvenWithEqualSpace() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let instanceId = fixture.localState.getInstanceId()?.string()
        var completion: ((String?) -> Void)?
        fixture.manager.initializeStoredAuthentication(loadActiveInstanceId: { completion = $0 }, initializeDevice: { _, _ in
            XCTFail("retired startup cannot publish into a replacement space")
            return true
        })
        fixture.manager.setActiveNetworkSpace(fixture.space)
        completion?(SdkNewId()?.string())
        try fixture.assertSessionRetained(instanceId: instanceId)
    }

    func testSupersededAndDuplicateBootstrapCallbacksCannotConstructOrChangeInstance() throws {
        let fixture = try StoredStartupFixture()
        defer { fixture.close() }
        let instanceId = fixture.localState.getInstanceId()?.string()
        var completions: [(String?) -> Void] = []
        var constructions = 0
        let initialize: (String, String) -> Bool = { _, _ in
            constructions += 1
            return true
        }
        fixture.manager.initializeStoredAuthentication(loadActiveInstanceId: { completions.append($0) }, initializeDevice: initialize)
        fixture.manager.initializeStoredAuthentication(loadActiveInstanceId: { completions.append($0) }, initializeDevice: initialize)
        completions[0](SdkNewId()?.string())
        XCTAssertEqual(constructions, 0)
        completions[1](nil)
        completions[1](SdkNewId()?.string())
        XCTAssertEqual(constructions, 1)
        try fixture.assertSessionRetained(instanceId: instanceId)
    }
}
