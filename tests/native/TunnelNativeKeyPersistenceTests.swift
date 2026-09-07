import Foundation
import URnetworkExtensionSdk
import XCTest
@testable import URnetwork

// Compile the whole production key adapter and session owner in an isolated
// native test module. Never run these through an app-hosted test target. All
// state is temporary; SDK endpoints are loopback and RPC is never enabled.
final class TunnelNativeKeyPersistenceTests: XCTestCase {
    func testNativeInitialKeySaveSurvivesColdReopenWithoutPreferencesOrSecretPersistence() throws {
        try withFixture { fixture in
            let firstStore = try fixture.openStore()
            try fixture.seed(firstStore)
            let first = try fixture.construct(firstStore, marker: 7)
            let expected = try XCTUnwrap(first.getKeyMaterial())
            let identity = first.getPublicIdentityKey()
            let preferenceSequence = try fixture.offModePreferenceSequence(firstStore, device: first)
            let failures = Counter()
            let adapter = TunnelDeviceKeyPersistence(device: first, isCurrent: { true }, reportFailure: failures.increment)
            XCTAssertEqual(adapter.save(), .saved)
            try fixture.requireMaterial(firstStore, expected)
            XCTAssertFalse(first.getProvideEnabled())
            XCTAssertFalse(first.getConnectEnabled())
            XCTAssertFalse(first.getAutoSave())
            XCTAssertEqual(try fixture.offModePreferenceSequence(firstStore, device: first), preferenceSequence)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.record(firstStore, ".provide_secret_keys").path))
            XCTAssertEqual(failures.value, 0)
            try fixture.close(firstStore)

            let reopened = try fixture.openStore()
            let saved = try XCTUnwrap(reopened.local.readDeviceLocalKeyMaterial().getKeyMaterial())
            let second = try fixture.construct(reopened, material: saved)
            XCTAssertTrue(second.getPublicIdentityKey() == identity, "cold construction changed retained provider identity")
            try fixture.requireMaterial(reopened, expected)
            XCTAssertFalse(second.getConnectEnabled())
            XCTAssertFalse(second.getAutoSave())
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.record(reopened, ".provide_secret_keys").path))
        }
    }

    func testNativeProviderKeyCallbackPersistsActualDeviceKeysOnly() throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let device = try fixture.construct(store, marker: 11)
            let preferenceSequence = try fixture.offModePreferenceSequence(store, device: device)
            let failures = Counter()
            let adapter = TunnelDeviceKeyPersistence(device: device, isCurrent: { true }, reportFailure: failures.increment)
            XCTAssertEqual(adapter.save(), .saved)
            let subscription = device.add(adapter)
            defer { subscription?.close() }
            let changed = try fixture.material(13)
            // This real SDK mutation invokes the production listener itself.
            device.setKeyMaterial(changed)
            let expected = try XCTUnwrap(device.getKeyMaterial())
            try fixture.requireMaterial(store, expected)
            XCTAssertTrue(expected.getClientKeySeed() == changed.getClientKeySeed())
            XCTAssertEqual(failures.value, 0)
            XCTAssertFalse(device.getAutoSave())
            XCTAssertEqual(try fixture.offModePreferenceSequence(store, device: device), preferenceSequence)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.record(store, ".provide_secret_keys").path))
        }
    }

    func testNativeRetiredKeyCallbackDoesNotWriteOrReportStorageFailure() throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let device = try fixture.construct(store, marker: 17)
            let expected = try XCTUnwrap(device.getKeyMaterial())
            try device.saveKeyMaterial()
            let owner = TunnelProviderSessionOwner<SdkDeviceLocal>()
            let (ticket, _) = try XCTUnwrap(owner.begin())
            XCTAssertTrue(owner.publish(device, ticket: ticket))
            let failures = Counter()
            let adapter = TunnelDeviceKeyPersistence(
                device: device, isCurrent: { owner.snapshot(ticket: ticket)?.value === device },
                reportFailure: failures.increment
            )
            let subscription = device.add(adapter)
            defer { subscription?.close() }
            _ = owner.take(ticket)
            device.setKeyMaterial(try fixture.material(19))
            try fixture.requireMaterial(store, expected)
            XCTAssertEqual(adapter.save(), .skipped)
            XCTAssertEqual(failures.value, 0)
        }
    }

    func testNativeHeldProviderKeyCallbackRejectsResetReplacement() throws {
        try assertHeldCallbackReplacement(reset: true)
    }

    func testNativeHeldProviderKeyCallbackRejectsEqualTokenReplacement() throws {
        try assertHeldCallbackReplacement(reset: false)
    }

    func testNativeHeldProviderKeyCallbackRejectsClosedDevice() throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let old = try fixture.construct(store, marker: 31)
            try old.saveKeyMaterial()
            let expected = try XCTUnwrap(old.getKeyMaterial())
            let failures = Counter()
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let adapter = TunnelDeviceKeyPersistence(device: old, isCurrent: {
                entered.signal()
                release.wait()
                return true
            }, reportFailure: failures.increment)
            let subscription = old.add(adapter)
            defer { subscription?.close() }
            let changed = try fixture.material(37)
            var completed = false
            defer {
                release.signal()
                if !completed { XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "held callback did not finish") }
            }
            DispatchQueue(label: "native-key-closed-control").async {
                old.setKeyMaterial(changed)
                finished.signal()
            }
            try requireSignal(entered)
            // The native admission already observed a live device. The actual
            // SDK save, entered only after release, must still reject Close.
            old.close()
            XCTAssertTrue(old.wait(forClose: 5_000), "old device did not join")
            release.signal()
            try requireSignal(finished)
            completed = true
            try fixture.requireMaterial(store, expected)
            XCTAssertEqual(failures.value, 1)
        }
    }

    func testNativeKeySaveAcceptsSettledSameOwnerRotationWithDistinctAdmin() throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let device = try fixture.construct(store, marker: 41)
            let renewed = try fixture.client(marker: "renewed", issuedAt: 1_800_000_020)
            device.setByJwt(renewed)
            XCTAssertTrue(store.local.getByClientJwt() == renewed)
            XCTAssertTrue(store.local.getByJwt() == fixture.admin)
            let failures = Counter()
            let adapter = TunnelDeviceKeyPersistence(device: device, isCurrent: { true }, reportFailure: failures.increment)
            XCTAssertEqual(adapter.save(), .saved)
            try fixture.requireMaterial(store, XCTUnwrap(device.getKeyMaterial()))
            XCTAssertEqual(failures.value, 0)
            XCTAssertFalse(device.getAutoSave())
        }
    }

    func testNativeKeySaveIoFailurePreservesIdentityAndReportOnlyPolicy() throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let device = try fixture.construct(store, marker: 43)
            let expected = try XCTUnwrap(device.getKeyMaterial())
            let preferenceSequence = try fixture.offModePreferenceSequence(store, device: device)
            let keyPath = try fixture.record(store, ".device_local_key_material")
            try FileManager.default.createDirectory(at: keyPath, withIntermediateDirectories: false)
            let failures = Counter()
            let adapter = TunnelDeviceKeyPersistence(device: device, isCurrent: { true }, reportFailure: failures.increment)
            XCTAssertEqual(adapter.save(), .failed)
            XCTAssertEqual(failures.value, 1)
            XCTAssertTrue(fixture.materialsEqual(device.getKeyMaterial(), expected), "failed save regenerated the live identity")
            XCTAssertTrue(store.local.getByClientJwt() == fixture.initial)
            XCTAssertTrue(store.local.getByJwt() == fixture.admin)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: keyPath.path).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.record(store, ".provide_secret_keys").path))
            XCTAssertFalse(device.getAutoSave())
            XCTAssertEqual(try fixture.offModePreferenceSequence(store, device: device), preferenceSequence)
            // reportFailure has no error/string parameter: private storage
            // paths or an NSError payload cannot reach the native reporter.
        }
    }

    func testNativeAlreadyClosedKeyOwnerSkipsWithoutMutation() throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let device = try fixture.construct(store, marker: 47)
            try device.saveKeyMaterial()
            let expected = try XCTUnwrap(device.getKeyMaterial())
            device.close()
            XCTAssertTrue(device.wait(forClose: 5_000), "device did not join")
            let failures = Counter()
            let adapter = TunnelDeviceKeyPersistence(device: device, isCurrent: { true }, reportFailure: failures.increment)
            XCTAssertEqual(adapter.save(), .skipped)
            try fixture.requireMaterial(store, expected)
            XCTAssertEqual(failures.value, 0)
        }
    }

    // The actual SDK SetKeyMaterial callback is held after native admission.
    // Both the real paired reset and equal-token owner replacement happen
    // before the same production adapter enters its final SDK key save.
    private func assertHeldCallbackReplacement(reset: Bool) throws {
        try withFixture { fixture in
            let store = try fixture.openStore()
            try fixture.seed(store)
            let old = try fixture.construct(store, marker: 53)
            try old.saveKeyMaterial()
            let owner = TunnelProviderSessionOwner<SdkDeviceLocal>()
            let (ticket, _) = try XCTUnwrap(owner.begin())
            XCTAssertTrue(owner.publish(old, ticket: ticket))
            let failures = Counter()
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let adapter = TunnelDeviceKeyPersistence(device: old, isCurrent: {
                let admitted = owner.snapshot(ticket: ticket)?.value === old
                guard admitted else { return false }
                entered.signal()
                release.wait()
                return admitted
            }, reportFailure: failures.increment)
            let subscription = old.add(adapter)
            defer { subscription?.close() }
            let changed = try fixture.material(59)
            var completed = false
            defer {
                release.signal()
                if !completed { XCTAssertEqual(finished.wait(timeout: .now() + 5), .success, "held callback did not finish") }
            }
            DispatchQueue(label: "native-key-replacement-control").async {
                old.setKeyMaterial(changed)
                finished.signal()
            }
            try requireSignal(entered)
            if reset {
                let snapshot = try XCTUnwrap(store.space.getAuthStateSnapshot())
                let result = try XCTUnwrap(store.space.resetLocalStateIfCurrent(snapshot))
                XCTAssertTrue(result.getReset(), "real current-owner reset did not complete")
                try fixture.seed(store)
            }
            let replacement = try fixture.construct(store, marker: 61)
            let (replacementTicket, _) = try XCTUnwrap(owner.begin())
            XCTAssertTrue(owner.publish(replacement, ticket: replacementTicket))
            try replacement.saveKeyMaterial()
            let expected = try XCTUnwrap(replacement.getKeyMaterial())
            release.signal()
            try requireSignal(finished)
            completed = true
            // State is the semantic counterfactual discriminator, not merely
            // a returned error. Never print synthetic key bytes on failure.
            let stored = try store.local.readDeviceLocalKeyMaterial().getKeyMaterial()
            XCTAssertTrue(
                fixture.materialsEqual(stored, expected),
                "late native key callback overwrote the replacement's durable state"
            )
            XCTAssertEqual(failures.value, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.record(store, ".provide_secret_keys").path))
        }
    }

    private func requireSignal(_ signal: DispatchSemaphore) throws {
        guard signal.wait(timeout: .now() + 5) == .success else {
            XCTFail("native callback boundary did not complete")
            throw FixtureError.boundary
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try body(fixture)
    }

    private enum FixtureError: Error { case boundary }

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private final class Store {
        let directory: URL
        let manager: SdkNetworkSpaceManager
        let space: SdkNetworkSpace
        let local: SdkLocalState
        var devices: [SdkDeviceLocal] = []
        var closed = false

        init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let created = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
            do {
                let values = SdkNetworkSpaceValues()
                values.apiUrl = "http://127.0.0.1:1"
                values.platformUrl = "ws://127.0.0.1:1"
                let key = try XCTUnwrap(SdkNewNetworkSpaceKey("native-key-save.test", "test"))
                let space = try XCTUnwrap(created.updateNetworkSpaceValues(key, values: values))
                local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
                self.space = space
                manager = created
            } catch {
                created.close()
                throw error
            }
        }
    }

    private final class Fixture {
        let directory: URL
        let instance: SdkId
        let initial: String
        let admin: String
        private var stores: [Store] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "private-marker-native-key-save-" + UUID().uuidString, isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instance = try XCTUnwrap(SdkNewId())
            initial = try Self.token(client: true, marker: "initial", issuedAt: 1_800_000_000)
            admin = try Self.token(client: false, marker: "distinct-admin", issuedAt: 1_800_000_000)
        }

        func openStore() throws -> Store {
            let store = try Store(directory: directory.appendingPathComponent("extension", isDirectory: true))
            stores.append(store)
            return store
        }

        func seed(_ store: Store) throws {
            try store.local.setByJwt(admin)
            try store.local.setByClientJwt(initial)
            try store.local.setInstanceId(instance)
        }

        func material(_ marker: UInt8) throws -> SdkDeviceLocalKeyMaterial {
            try XCTUnwrap(SdkNewDeviceLocalKeyMaterial(Data(repeating: marker, count: 32), nil, nil))
        }

        func construct(_ store: Store, marker: UInt8) throws -> SdkDeviceLocal {
            try construct(store, material: material(marker))
        }

        func construct(_ store: Store, material: SdkDeviceLocalKeyMaterial) throws -> SdkDeviceLocal {
            var error: NSError?
            let created = SdkNewDeviceLocalWithMemoryTarget(
                store.space, store.local.getByClientJwt(), "native-key-save", "test", "0",
                instance, false, material, 20 * 1024 * 1024, &error
            )
            if let error {
                if let created {
                    // Even an NSError plus a nonnil partial result remains an
                    // owned SDK graph. Retain it for cleanup if this join fails.
                    store.devices.append(created)
                    created.close()
                    guard created.wait(forClose: 5_000) else {
                        XCTFail("partial native key fixture owner did not join")
                        throw FixtureError.boundary
                    }
                }
                throw error
            }
            let device = try XCTUnwrap(created)
            store.devices.append(device)
            device.setProvideControlMode("never")
            device.setProvidePaused(true)
            device.setDnsResolverSettings(SdkDnsResolverSettings())
            XCTAssertFalse(device.getAutoSave())
            XCTAssertFalse(device.getConnectEnabled())
            return device
        }

        func record(_ store: Store, _ name: String) throws -> URL {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: store.directory, includingPropertiesForKeys: nil))
            let envelopes = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == ".auth_state" }
            XCTAssertEqual(envelopes.count, 1)
            return try XCTUnwrap(envelopes.first).deletingLastPathComponent().appendingPathComponent(name)
        }

        func materialsEqual(_ first: SdkDeviceLocalKeyMaterial?, _ second: SdkDeviceLocalKeyMaterial?) -> Bool {
            guard let first, let second else { return false }
            return first.getClientKeySeed() == second.getClientKeySeed()
                && first.getProvideTlsCertificatePem() == second.getProvideTlsCertificatePem()
                && first.getProvideTlsPrivateKeyPem() == second.getProvideTlsPrivateKeyPem()
        }

        func requireMaterial(_ store: Store, _ expected: SdkDeviceLocalKeyMaterial) throws {
            XCTAssertTrue(materialsEqual(try store.local.readDeviceLocalKeyMaterial().getKeyMaterial(), expected), "durable key material differs from the accepted device")
        }

        // Setup changes live providing/DNS policy with autosave off. That
        // records an unsaved preference operation; key saves must not change it.
        func offModePreferenceSequence(_ store: Store, device: SdkDeviceLocal) throws -> Int64 {
            let result = try XCTUnwrap(device.getLastStateSaveResult())
            XCTAssertEqual(result.getPreference(), "dns-resolver-settings")
            XCTAssertFalse(result.getAutoSaveEnabled())
            XCTAssertFalse(result.getSaved())
            XCTAssertTrue(result.getError().isEmpty)
            for name in [".connect_location", ".default_location", ".provide_control_mode", ".dns_resolver_settings"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: try record(store, name).path),
                               "key fixture unexpectedly persisted a preference")
            }
            return result.getSequence()
        }

        func client(marker: String, issuedAt: Int64) throws -> String {
            try Self.token(client: true, marker: marker, issuedAt: issuedAt)
        }

        func close(_ store: Store) throws {
            guard !store.closed else { return }
            for device in store.devices.reversed() {
                device.close()
                guard device.wait(forClose: 5_000) else {
                    XCTFail("native key fixture owner did not join")
                    throw FixtureError.boundary
                }
            }
            store.manager.close()
            store.closed = true
        }

        func cleanUp() {
            for store in stores.reversed() where !store.closed {
                do { try close(store) } catch { XCTFail("native key fixture cleanup failed") }
            }
            if stores.allSatisfy({ $0.closed }) { try? FileManager.default.removeItem(at: directory) }
        }

        private static func token(client: Bool, marker: String, issuedAt: Int64) throws -> String {
            var claims: [String: Any] = [
                "user_id": "00000000-0000-0000-0000-000000000003",
                "network_id": "00000000-0000-0000-0000-000000000004",
                "iat": issuedAt, "exp": Int64(2_000_000_000), "marker": marker
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
