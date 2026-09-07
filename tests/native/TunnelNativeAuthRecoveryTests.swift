import Foundation
import URnetworkExtensionSdk
import XCTest
@testable import URnetwork

// Real DeviceLocal, temporary auth/preference storage, production settlement
// observer and checked destination adapter. The initial unsettled read below
// is deliberately injected at the native observation boundary. SetByJwt then
// produces a REAL device publication callback; this is not the separate Go
// test's held API-ahead/disk-old refresh. No app, RPC, VPN/profile or NE instance.
final class TunnelNativeAuthRecoveryTests: XCTestCase {
    func testNativeActualPublicationResumesPendingDestinationWithoutRpc() throws {
        try assertPublicationRestoresDestination(afterDeadline: false)
    }

    func testNativeActualPublicationAfterDeadlineStillRestoresDestination() throws {
        try assertPublicationRestoresDestination(afterDeadline: true)
    }

    func testNativeHealthyPublicationDoesNoRecoveryOrPreferenceMutation() throws {
        try withFixture { fixture in
            let device = try fixture.construct()
            try device.setAutoSave(true)
            let target = try fixture.location("healthy-specific")
            try applyTunnelRecoveryDestination(device, location: target)
            let sequence = try XCTUnwrap(device.getLastStateSaveResult()).getSequence()
            let original = try Data(contentsOf: fixture.record(".connect_location"))
            let driver = Driver(device: device)
            let recovery = driver.make()
            defer { recovery.cancel() }
            let observer = TunnelDeviceAuthSettlementObserver(
                device: device, isCurrent: { true }, settled: { recovery.settled() }
            )
            let subscription = device.add(observer)
            defer { subscription?.close() }
            device.setByJwt(try fixture.refreshed())
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 0)
            XCTAssertEqual(try XCTUnwrap(device.getLastStateSaveResult()).getSequence(), sequence)
            XCTAssertTrue(try Data(contentsOf: fixture.record(".connect_location")) == original)
            XCTAssertTrue(device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(device.getConnectLocation()).equals(target))
        }
    }

    func testNativeLiveDisconnectRetiresPendingConnectBeforePublication() throws {
        try assertNewLiveChoiceRetiresPending(disconnect: true)
    }

    func testNativeNewLiveDestinationRetiresOldPendingChoice() throws {
        try assertNewLiveChoiceRetiresPending(disconnect: false)
    }

    func testNativeQueuedPublicationFromRetiredProviderCannotReadReplacement() throws {
        try withFixture { fixture in
            let device = try fixture.construct()
            try device.setAutoSave(true)
            let owner = TunnelProviderSessionOwner<SdkDeviceLocal>()
            let (ticket, _) = try XCTUnwrap(owner.begin())
            XCTAssertTrue(owner.publish(device, ticket: ticket))
            let current = { owner.snapshot(ticket: ticket)?.value === device }
            let driver = Driver(device: device, current: current)
            let recovery = driver.make()
            defer { recovery.cancel() }
            let observer = TunnelDeviceAuthSettlementObserver(
                device: device, isCurrent: current, settled: { recovery.settled() }
            )
            let subscription = device.add(observer)
            defer { subscription?.close() }
            recovery.request(1, reason: .wake)
            driver.queue.drain()
            driver.blocked = false
            driver.target = try fixture.location("retired-request")
            device.setByJwt(try fixture.refreshed())
            XCTAssertEqual(driver.queue.count, 1)
            _ = owner.take(ticket)
            let replacement = try fixture.construct()
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertFalse(replacement.getConnectEnabled())
            XCTAssertNil(try fixture.local.readConnectLocation().getLocation())
        }
    }

    func testNativeCheckedWriteFailureDoesNotAwaitOrRetryOnPublication() throws {
        try withFixture { fixture in
            let device = try fixture.construct()
            try device.setAutoSave(true)
            let target = try fixture.location("write-error")
            let record = try fixture.record(".connect_location")
            try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
            let driver = Driver(device: device)
            driver.blocked = false
            driver.target = target
            let recovery = driver.make()
            defer { recovery.cancel() }
            let observer = TunnelDeviceAuthSettlementObserver(
                device: device, isCurrent: { true }, settled: { recovery.settled() }
            )
            let subscription = device.add(observer)
            defer { subscription?.close() }
            recovery.request(1, reason: .wake)
            driver.queue.drain()
            XCTAssertEqual(driver.failures, 1)
            XCTAssertFalse(device.getConnectEnabled())
            XCTAssertTrue(driver.phases.isEmpty)
            device.setByJwt(try fixture.refreshed())
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertEqual(driver.failures, 1)
            XCTAssertFalse(device.getConnectEnabled())
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue, "a failed checked write replaced the obstructing record")
            XCTAssertFalse(driver.phases.joined().contains("private-marker"))
            XCTAssertTrue(fixture.local.getByJwt() == fixture.admin)
        }
    }

    private func assertPublicationRestoresDestination(afterDeadline: Bool) throws {
        try withFixture { fixture in
            let device = try fixture.construct()
            try device.setAutoSave(true)
            let target = try fixture.location("accepted-specific-current")
            let driver = Driver(device: device)
            driver.target = target
            let recovery = driver.make()
            defer { recovery.cancel() }
            let observer = TunnelDeviceAuthSettlementObserver(
                device: device, isCurrent: { true }, settled: { recovery.settled() },
                accepted: { _ in driver.mirrors += 1 }
            )
            let subscription = device.add(observer)
            defer { subscription?.close() }
            recovery.request(1, reason: .wake)
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertEqual(driver.queue.count, 0)
            XCTAssertNil(try fixture.local.readConnectLocation().getLocation())
            XCTAssertFalse(device.getConnectEnabled())
            if afterDeadline { driver.deadlines.last?() }
            driver.blocked = false
            let refreshed = try fixture.refreshed()
            device.setByJwt(refreshed)
            // The actual SDK callback follows its current durable publication.
            XCTAssertTrue(fixture.local.getByClientJwt() == refreshed)
            XCTAssertTrue(device.getClientJwt() == refreshed)
            XCTAssertEqual(driver.attempts, 1, "device callback performed recovery inline")
            driver.queue.drain()
            let saved = try fixture.local.readConnectLocation().getLocation()
            XCTAssertTrue(
                saved?.equals(target) == true && device.getConnectEnabled(),
                "settled native recovery left the exact current destination unpersisted or without a consumer"
            )
            XCTAssertTrue(device.getConnectLocation()?.equals(target) == true)
            XCTAssertEqual(driver.attempts, 2)
            XCTAssertEqual(driver.failures, 0)
            XCTAssertEqual(driver.completions, 1)
            XCTAssertEqual(driver.mirrors, 1)
            XCTAssertTrue(fixture.local.getByJwt() == fixture.admin)
        }
    }

    private func assertNewLiveChoiceRetiresPending(disconnect: Bool) throws {
        try withFixture { fixture in
            let device = try fixture.construct()
            try device.setAutoSave(true)
            try applyTunnelRecoveryDestination(device, location: fixture.location("initial-live"))
            let holder = TunnelRecoverySession<String, String>()
            let session = holder.begin(owner: "current", savedLocationHasCurrentOwner: true)
            let initialTicket = try XCTUnwrap(holder.snapshot(ticket: session)).destinationTicket
            let driver = Driver(device: device)
            let recovery = TunnelAuthRecoveryContinuation<TunnelRecoverySession<String, String>.DestinationTicket>(
                enqueue: driver.queue.append,
                scheduleDeadline: { expire in driver.deadlines.append(expire); return {} },
                isCurrent: { holder.isCurrent($0) },
                observe: { _ in driver.attempts += 1; throw Driver.unsettled },
                completed: { _, _ in driver.completions += 1 },
                failed: { _ in driver.failures += 1 }
            )
            defer { recovery.cancel() }
            let observer = TunnelDeviceAuthSettlementObserver(
                device: device, isCurrent: { holder.isCurrent(session) },
                settled: { recovery.settled() }
            )
            let authSubscription = device.add(observer)
            // This actual SDK callback drives the same production holder and
            // stale-pending retirement methods as PTP, before UI publication.
            let choiceSubscription = device.add(ChoiceListener {
                _ = holder.noteDestinationChange(ticket: session)
                recovery.retireStalePending()
            })
            defer { choiceSubscription?.close(); authSubscription?.close() }
            recovery.request(initialTicket, reason: .wake)
            driver.queue.drain()
            let replacement: SdkConnectLocation?
            if disconnect { replacement = nil }
            else { replacement = try fixture.location("new-current-choice") }
            try applyTunnelRecoveryDestination(device, location: replacement)
            device.setByJwt(try fixture.refreshed())
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertEqual(driver.completions, 0)
            let saved = try fixture.local.readConnectLocation().getLocation()
            if let replacement {
                XCTAssertTrue(saved?.equals(replacement) == true)
                XCTAssertTrue(device.getConnectLocation()?.equals(replacement) == true)
                XCTAssertTrue(device.getConnectEnabled())
            } else {
                XCTAssertNil(saved)
                XCTAssertNil(device.getConnectLocation())
                XCTAssertFalse(device.getConnectEnabled())
            }
        }
    }

    private final class ChoiceListener: NSObject, SdkConnectLocationChangeListenerProtocol {
        let callback: () -> Void
        init(_ callback: @escaping () -> Void) { self.callback = callback }
        func connectLocationChanged(_ location: SdkConnectLocation?) { callback() }
    }

    private final class Driver {
        static var unsettled: NSError {
            NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"])
        }
        let device: SdkDeviceLocal
        let current: () -> Bool
        let queue = Queue()
        var blocked = true
        var target: SdkConnectLocation?
        var attempts = 0
        var failures = 0
        var completions = 0
        var mirrors = 0
        var phases: [String] = []
        var deadlines: [() -> Void] = []
        init(device: SdkDeviceLocal, current: @escaping () -> Bool = { true }) {
            self.device = device
            self.current = current
        }
        func make() -> TunnelAuthRecoveryContinuation<Int> {
            TunnelAuthRecoveryContinuation(
                enqueue: queue.append,
                scheduleDeadline: { expire in self.deadlines.append(expire); return {} },
                isCurrent: { _ in self.current() && !self.device.getDone() },
                observe: { _ in
                    self.attempts += 1
                    if self.blocked { throw Self.unsettled }
                    try applyTunnelRecoveryDestination(self.device, location: self.target)
                },
                completed: { _, _ in self.completions += 1 },
                failed: { _ in self.failures += 1 },
                report: { _, phase in self.phases.append(phase == .waiting ? "waiting" : "timeout") }
            )
        }
    }

    private final class Queue {
        private let lock = NSLock()
        private var work: [() -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return work.count }
        func append(_ action: @escaping () -> Void) { lock.lock(); work.append(action); lock.unlock() }
        private func take() -> (() -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return work.isEmpty ? nil : work.removeFirst()
        }
        func drain() {
            var count = 0
            while let action = take() {
                count += 1
                guard count <= 32 else { XCTFail("native recovery entered an unbounded retry"); return }
                action()
            }
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try body(fixture)
    }

    private enum FixtureError: Error { case boundary }
    private final class Fixture {
        let directory: URL
        let manager: SdkNetworkSpaceManager
        let space: SdkNetworkSpace
        let local: SdkLocalState
        let instance: SdkId
        let admin: String
        private var devices: [SdkDeviceLocal] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "private-marker-native-auth-recovery-" + UUID().uuidString, isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instance = try XCTUnwrap(SdkNewId())
            admin = try Self.token(client: false, marker: "admin")
            let created = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
            do {
                let values = SdkNetworkSpaceValues()
                values.apiUrl = "http://127.0.0.1:1"
                values.platformUrl = "ws://127.0.0.1:1"
                let key = try XCTUnwrap(SdkNewNetworkSpaceKey("native-auth-recovery.test", "test"))
                let space = try XCTUnwrap(created.updateNetworkSpaceValues(key, values: values))
                local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
                self.space = space
                manager = created
                try local.setByJwt(admin)
                try local.setByClientJwt(Self.token(client: true, marker: "initial"))
                try local.setInstanceId(instance)
            } catch {
                created.close()
                throw error
            }
        }

        func construct() throws -> SdkDeviceLocal {
            let material = try XCTUnwrap(SdkNewDeviceLocalKeyMaterial(Data(repeating: 7, count: 32), nil, nil))
            var error: NSError?
            let created = SdkNewDeviceLocalWithMemoryTarget(
                space, local.getByClientJwt(), "native-auth-recovery", "test", "0",
                instance, false, material, 20 * 1024 * 1024, &error
            )
            if let error {
                if let created {
                    devices.append(created)
                    created.close()
                    guard created.wait(forClose: 5_000) else {
                        XCTFail("partial native recovery fixture did not join")
                        throw FixtureError.boundary
                    }
                }
                throw error
            }
            let device = try XCTUnwrap(created)
            devices.append(device)
            device.setProvideControlMode("never")
            device.setProvidePaused(true)
            device.setDnsResolverSettings(SdkDnsResolverSettings())
            XCTAssertFalse(device.getAutoSave())
            XCTAssertFalse(device.getConnectEnabled())
            return device
        }

        func location(_ name: String) throws -> SdkConnectLocation {
            let id = SdkConnectLocationId()
            id.locationId = try XCTUnwrap(SdkNewId())
            let location = SdkConnectLocation()
            location.connectLocationId = id
            location.name = name
            return location
        }

        func record(_ name: String) throws -> URL {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            let envelopes = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == ".auth_state" }
            XCTAssertEqual(envelopes.count, 1)
            return try XCTUnwrap(envelopes.first).deletingLastPathComponent().appendingPathComponent(name)
        }

        func refreshed() throws -> String { try Self.token(client: true, marker: "refreshed") }

        func cleanUp() {
            for device in devices.reversed() {
                device.close()
                guard device.wait(forClose: 5_000) else {
                    XCTFail("native recovery fixture did not join; retaining its store")
                    return
                }
            }
            manager.close()
            try? FileManager.default.removeItem(at: directory)
        }

        private static func token(client: Bool, marker: String) throws -> String {
            var claims: [String: Any] = [
                "user_id": "00000000-0000-0000-0000-000000000003",
                "network_id": "00000000-0000-0000-0000-000000000004",
                "iat": Int64(1_800_000_000), "exp": Int64(2_000_000_000), "marker": marker
            ]
            if client {
                claims["client_id"] = "00000000-0000-0000-0000-000000000001"
                claims["device_id"] = "00000000-0000-0000-0000-000000000002"
            }
            func encode(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
            let payload = try JSONSerialization.data(withJSONObject: claims)
            return encode(header) + "." + encode(payload) + "."
        }
    }
}
