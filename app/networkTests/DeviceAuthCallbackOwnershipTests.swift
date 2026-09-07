import Foundation
import XCTest
@testable import URnetwork

// Work is held explicitly, not delayed by sleeps or scheduler assumptions.
// The lock protects only the queue; no callback executes while it is held.
private final class DeviceAuthHeldDispatcher: @unchecked Sendable {
    private let stateLock = NSLock()
    private var pending: [DeviceAuthCallbackWork] = []

    func enqueue(_ work: @escaping DeviceAuthCallbackWork) {
        stateLock.lock()
        pending.append(work)
        stateLock.unlock()
    }

    @MainActor @discardableResult
    func deliverBatch() -> Int {
        let batch: [DeviceAuthCallbackWork] = {
            stateLock.lock()
            defer { stateLock.unlock() }
            let batch = pending
            pending.removeAll()
            return batch
        }()
        for work in batch { work() }
        return batch.count
    }
}

// Registration goes through the actual DeviceManager method. Retaining the
// callback after close models an SDK callback already admitted before removal.
private final class DeviceAuthTestingSource: DeviceAuthCallbackSource {
    let instanceId: String?
    private(set) var refreshCloses = 0
    private(set) var logoutCloses = 0
    private var refresh: (@Sendable (String?) -> Void)?
    private var logout: (@Sendable () -> Void)?

    init(instanceId: String? = "same-instance") {
        self.instanceId = instanceId
    }

    func authCallbackInstanceId() -> String? { instanceId }

    func observeAuthRefresh(_ callback: @escaping @Sendable (String?) -> Void) -> () -> Void {
        refresh = callback
        return { [weak self] in self?.refreshCloses += 1 }
    }

    func observeAuthLogout(_ callback: @escaping @Sendable () -> Void) -> () -> Void {
        logout = callback
        return { [weak self] in self?.logoutCloses += 1 }
    }

    func emitRefresh(_ jwt: String?) { refresh?(jwt) }
    func emitLogout() { logout?() }
}

// These sinks stand in for the externally destructive operations only.
// Actual DeviceManager registration, dispatch, admission and logout entry run.
@MainActor
private final class DeviceAuthMemoryEffects {
    var admin = "admin-current"
    var client = "client-current"
    var instance = "same-instance"
    var profiles = 1
    var refreshWrites = 0
    var logouts = 0

    func persist(_ jwt: String, instanceId: String) {
        refreshWrites += 1
        client = jwt
        instance = instanceId
    }

    func clear() {
        logouts += 1
        admin = ""
        client = ""
        instance = ""
        profiles = 0
    }
}

@MainActor
private struct DeviceAuthTestingFixture {
    let dispatcher: DeviceAuthHeldDispatcher
    let effects: DeviceAuthMemoryEffects
    let manager: DeviceManager

    init(startupMode: AppStartupMode = .production) {
        let dispatcher = DeviceAuthHeldDispatcher()
        let effects = DeviceAuthMemoryEffects()
        self.dispatcher = dispatcher
        self.effects = effects
        manager = DeviceManager(
            startupMode: startupMode,
            automaticallyInitialize: false,
            authCallbackDispatch: { dispatcher.enqueue($0) },
            authCallbackEffects: DeviceAuthCallbackEffects(
                persistRefresh: { effects.persist($0, instanceId: $1) },
                logout: { manager in
                    if manager.beginLogout() { effects.clear() }
                }
            )
        )
    }
}

// Both iOS and macOS compile this shared production manager. The stock test
// target launches the app host, so runtime execution additionally requires an
// independently verified inert host; these bodies never start SDK RPC, read
// Keychain, load/save NE preferences, or install a device/profile.
@MainActor
final class DeviceAuthCallbackOwnershipTests: XCTestCase {
    func testHardwareNoVPNRefreshCannotPublishTunnelCredential() {
        let fixture = DeviceAuthTestingFixture(startupMode: .hardwareNoVPN)
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitRefresh("client-refreshed")
        XCTAssertEqual(fixture.dispatcher.deliverBatch(), 1)
        XCTAssertEqual(fixture.effects.refreshWrites, 0)
        XCTAssertEqual(fixture.effects.admin, "admin-current")
        XCTAssertEqual(fixture.effects.client, "client-current")
    }

    func testHardwareNoVPNCurrentRejectionStillEntersLogout() {
        let fixture = DeviceAuthTestingFixture(startupMode: .hardwareNoVPN)
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        fixture.dispatcher.deliverBatch()
        // This is admission into the injected memory sink, not a profile API.
        XCTAssertEqual(fixture.effects.logouts, 1)
    }

    func testHardwareNoVPNRetiredRejectionCannotClearReplacement() {
        let fixture = DeviceAuthTestingFixture(startupMode: .hardwareNoVPN)
        let old = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: old)
        old.emitLogout()
        fixture.manager.setupDeviceAuthListeners(source: DeviceAuthTestingSource())
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 0)
        XCTAssertEqual(fixture.effects.admin, "admin-current")
        XCTAssertEqual(fixture.effects.client, "client-current")
    }

    func testEqualAdminLoginRetiresAlreadyQueuedRejection() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        fixture.manager.acceptNetworkLogin {
            fixture.effects.admin = "admin-current"
        }
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 0)
        XCTAssertEqual(fixture.effects.admin, "admin-current")
    }

    func testQueuedOldLogoutCannotClearReplacementAuth() {
        let fixture = DeviceAuthTestingFixture()
        let old = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: old)
        old.emitLogout()
        let current = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: current)

        XCTAssertEqual(old.refreshCloses, 1)
        XCTAssertEqual(old.logoutCloses, 1)
        XCTAssertEqual(fixture.dispatcher.deliverBatch(), 1)
        XCTAssertEqual(fixture.effects.logouts, 0, "retired device logout reached current auth")
        XCTAssertTrue(fixture.effects.admin == "admin-current", "retired logout cleared current admin")
        XCTAssertTrue(fixture.effects.client == "client-current", "retired logout cleared current client")
        XCTAssertEqual(fixture.effects.profiles, 1, "retired logout removed current profiles")
    }

    func testQueuedOldRefreshCannotPublishIntoReplacement() {
        let fixture = DeviceAuthTestingFixture()
        let old = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: old)
        old.emitRefresh("client-retired")
        let current = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: current)

        XCTAssertEqual(fixture.dispatcher.deliverBatch(), 1)
        XCTAssertEqual(fixture.effects.refreshWrites, 0, "retired device refresh reached current restart auth")
        XCTAssertTrue(fixture.effects.client == "client-current", "retired refresh replaced current client")
        current.emitRefresh("client-next-refresh")
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 1)
    }

    func testRepeatedRegistrationOfSameSourceRetiresQueuedOwner() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        fixture.manager.setupDeviceAuthListeners(source: source)
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 0, "equal source identity reused a retired callback owner")

        source.emitRefresh("client-refreshed")
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 1)
        XCTAssertTrue(fixture.effects.client == "client-refreshed")
    }

    func testSingleCurrentLogoutStillClearsAuth() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 1)
        XCTAssertTrue(fixture.effects.admin.isEmpty)
        XCTAssertTrue(fixture.effects.client.isEmpty)
        XCTAssertEqual(fixture.effects.profiles, 0)
    }

    func testCurrentLogoutDoesNotAllowQueuedRefreshToReviveAuth() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        source.emitLogout()
        source.emitRefresh("client-after-logout")

        XCTAssertEqual(fixture.dispatcher.deliverBatch(), 3)
        XCTAssertEqual(fixture.effects.logouts, 1)
        XCTAssertEqual(fixture.effects.refreshWrites, 0)
        XCTAssertTrue(fixture.effects.admin.isEmpty)
        XCTAssertTrue(fixture.effects.client.isEmpty)
        XCTAssertTrue(fixture.effects.instance.isEmpty)
        XCTAssertEqual(fixture.effects.profiles, 0)
    }

    func testCurrentRefreshPreservesAdminAndInstance() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitRefresh("client-refreshed")
        fixture.dispatcher.deliverBatch()

        XCTAssertEqual(fixture.effects.refreshWrites, 1)
        XCTAssertTrue(fixture.effects.admin == "admin-current")
        XCTAssertTrue(fixture.effects.client == "client-refreshed")
        XCTAssertTrue(fixture.effects.instance == "same-instance")
        XCTAssertEqual(fixture.effects.logouts, 0)
    }

    func testPendingLoginDoesNotRetireServingCallbacks() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        // No admin commit has been accepted while the outer request is pending.
        source.emitRefresh("client-while-login-pending")
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 1)
        XCTAssertTrue(fixture.effects.admin == "admin-current")
    }

    func testFailedAdminWriteLeavesServingCallbacksCurrent() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitRefresh("client-after-failed-login")
        enum WriteFailure: Error { case refused }
        XCTAssertThrowsError(try fixture.manager.acceptNetworkLogin { throw WriteFailure.refused })
        fixture.dispatcher.deliverBatch()

        XCTAssertEqual(fixture.effects.refreshWrites, 1)
        XCTAssertTrue(fixture.effects.admin == "admin-current")
    }

    func testAcceptedAdminRetiresOldCallbacksBeforeReplacementExists() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        source.emitRefresh("client-retired")
        fixture.manager.acceptNetworkLogin {
            fixture.effects.admin = "admin-next"
            fixture.effects.client = ""
            fixture.effects.instance = ""
        }
        // The same old source remains installed while client registration waits.
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 0, "old rejection cleared an accepted explicit login")
        XCTAssertEqual(fixture.effects.refreshWrites, 0)
        XCTAssertTrue(fixture.effects.admin == "admin-next")
        XCTAssertTrue(fixture.effects.client.isEmpty)
    }

    func testAcceptedAdminStaysProtectedWhenOnboardingWriteFails() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        enum OnboardingFailure: Error { case refused }
        do {
            fixture.manager.acceptNetworkLogin { fixture.effects.admin = "admin-next" }
            throw OnboardingFailure.refused
        } catch {}
        fixture.dispatcher.deliverBatch()

        XCTAssertEqual(fixture.effects.logouts, 0, "onboarding failure restored a retired device owner")
        XCTAssertTrue(fixture.effects.admin == "admin-next")
    }

    func testExplicitLogoutEntryRetiresAlreadyQueuedCallbacks() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitRefresh("client-retired")
        source.emitLogout()
        XCTAssertTrue(fixture.manager.beginLogout())
        XCTAssertFalse(fixture.manager.beginLogout())
        fixture.dispatcher.deliverBatch()

        XCTAssertEqual(fixture.effects.refreshWrites, 0)
        XCTAssertEqual(fixture.effects.logouts, 0)
    }

    func testAcceptedNetworkAssignmentRetiresQueuedDeviceCallbacks() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        fixture.manager.setActiveNetworkSpace(nil)
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 0)
    }

    func testClearDeviceRetiresCallbackEvenAfterSourceRemoval() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        fixture.manager.clearDevice()
        source.emitRefresh("late-retired-client")
        source.emitLogout()
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 0)
        XCTAssertEqual(fixture.effects.logouts, 0)
    }

    func testQuitRetiresQueuedCallbacksWithoutStartingLogout() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitLogout()
        var completions = 0
        fixture.manager.closeOnQuit { error in
            XCTAssertNil(error)
            completions += 1
        }
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(fixture.effects.logouts, 0)
    }

    func testMalformedRefreshDoesNotPublishOrRetireCurrentOwner() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource()
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitRefresh(nil)
        source.emitRefresh("")
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 0)

        source.emitRefresh("client-refreshed")
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 1)
    }

    func testMissingInstanceBlocksRefreshButNotCurrentRejection() {
        let fixture = DeviceAuthTestingFixture()
        let source = DeviceAuthTestingSource(instanceId: nil)
        fixture.manager.setupDeviceAuthListeners(source: source)
        source.emitRefresh("client-refreshed")
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.refreshWrites, 0)

        source.emitLogout()
        fixture.dispatcher.deliverBatch()
        XCTAssertEqual(fixture.effects.logouts, 1)
    }
}
