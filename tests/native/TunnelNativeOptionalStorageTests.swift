import Foundation
#if canImport(URnetworkExtensionSdk)
import URnetworkExtensionSdk
#else
import URnetworkSdk
#endif
import XCTest

// Actual generated-SDK boundary tests, with no app host or provider. A nonnil
// checked read result carries absence through its error-free optional getter;
// storage failure still throws before the value can be observed.
final class TunnelNativeOptionalStorageTests: XCTestCase {
    func testMissingLocalConnectLocationIsNilWithoutError() throws {
        try assertMissingLocation(.localConnect)
    }

    func testMissingLocalDefaultLocationIsNilWithoutError() throws {
        try assertMissingLocation(.localDefault)
    }

    func testMissingSnapshotConnectLocationIsNilWithoutError() throws {
        try assertMissingLocation(.snapshotConnect)
    }

    func testMissingSnapshotDefaultLocationIsNilWithoutError() throws {
        try assertMissingLocation(.snapshotDefault)
    }

    func testMissingKeyMaterialIsNilWithoutError() throws {
        try withFixture { fixture in
            let record = fixture.record(".device_local_key_material")
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
            XCTAssertNil(try fixture.local.readDeviceLocalKeyMaterial().getKeyMaterial())
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        }
    }

    func testLegacyEmptyKeyMaterialIsNilWithoutErrorAndUnchanged() throws {
        try assertLegacyEmptyKeyMaterial("{}")
    }

    func testLegacyNullKeyMaterialIsNilWithoutErrorAndUnchanged() throws {
        try assertLegacyEmptyKeyMaterial("null")
    }

    func testPresentLocalConnectLocationLoadsWithoutMutation() throws {
        try assertPresentLocation(.localConnect)
    }

    func testPresentLocalDefaultLocationLoadsWithoutMutation() throws {
        try assertPresentLocation(.localDefault)
    }

    func testPresentSnapshotConnectLocationLoadsWithoutMutation() throws {
        try assertPresentLocation(.snapshotConnect)
    }

    func testPresentSnapshotDefaultLocationLoadsWithoutMutation() throws {
        try assertPresentLocation(.snapshotDefault)
    }

    func testPresentKeyMaterialLoadsWithoutMutation() throws {
        try withFixture { fixture in
            let expected = try XCTUnwrap(SdkNewDeviceLocalKeyMaterial(Data(repeating: 7, count: 32), nil, nil))
            try fixture.local.setDeviceLocalKeyMaterial(expected)
            let record = fixture.record(".device_local_key_material")
            let before = try Data(contentsOf: record)
            let actual = try XCTUnwrap(fixture.local.readDeviceLocalKeyMaterial().getKeyMaterial())
            XCTAssertFalse(actual.isEmpty())
            XCTAssertTrue(actual.getClientKeySeed() == expected.getClientKeySeed(), "loaded key material changed")
            XCTAssertTrue(actual.getProvideTlsCertificatePem() == expected.getProvideTlsCertificatePem(), "loaded certificate changed")
            XCTAssertTrue(actual.getProvideTlsPrivateKeyPem() == expected.getProvideTlsPrivateKeyPem(), "loaded private key changed")
            XCTAssertTrue(try Data(contentsOf: record) == before, "key read changed its record")
        }
    }

    func testMalformedLocalConnectLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.localConnect, json: "{")
    }

    func testMalformedLocalDefaultLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.localDefault, json: "{")
    }

    func testMalformedSnapshotConnectLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.snapshotConnect, json: "{")
    }

    func testMalformedSnapshotDefaultLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.snapshotDefault, json: "{")
    }

    func testMalformedKeyMaterialThrowsWithoutRepair() throws {
        try withFixture { fixture in
            let record = fixture.record(".device_local_key_material")
            let before = try fixture.write("{", to: record)
            assertStorageError("decode device key material") {
                try fixture.local.readDeviceLocalKeyMaterial().getKeyMaterial()
            }
            XCTAssertTrue(try Data(contentsOf: record) == before, "failed key read changed its record")
        }
    }

    func testNullLocalConnectLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.localConnect, json: "null")
    }

    func testNullLocalDefaultLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.localDefault, json: "null")
    }

    func testNullSnapshotConnectLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.snapshotConnect, json: "null")
    }

    func testNullSnapshotDefaultLocationThrowsWithoutRepair() throws {
        try assertInvalidLocation(.snapshotDefault, json: "null")
    }

    func testUnreadableLocalConnectLocationThrowsWithoutRepair() throws {
        try assertUnreadableLocation(.localConnect)
    }

    func testUnreadableLocalDefaultLocationThrowsWithoutRepair() throws {
        try assertUnreadableLocation(.localDefault)
    }

    func testUnreadableSnapshotConnectLocationThrowsWithoutRepair() throws {
        try assertUnreadableLocation(.snapshotConnect)
    }

    func testUnreadableSnapshotDefaultLocationThrowsWithoutRepair() throws {
        try assertUnreadableLocation(.snapshotDefault)
    }

    func testUnreadableKeyMaterialThrowsWithoutRepair() throws {
        try withFixture { fixture in
            let record = fixture.record(".device_local_key_material")
            let target = try fixture.makeDanglingSymlink(at: record)
            assertStorageError("resolve device key material") {
                try fixture.local.readDeviceLocalKeyMaterial().getKeyMaterial()
            }
            XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: record.path) == target.path,
                          "failed key read changed its symlink")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    private func assertMissingLocation(_ read: LocationRead) throws {
        try withFixture { fixture in
            let record = fixture.record(read.recordName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
            XCTAssertNil(try read.load(fixture))
            XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
        }
    }

    private func assertLegacyEmptyKeyMaterial(_ json: String) throws {
        try withFixture { fixture in
            let record = fixture.record(".device_local_key_material")
            let before = try fixture.write(json, to: record)
            XCTAssertNil(try fixture.local.readDeviceLocalKeyMaterial().getKeyMaterial())
            XCTAssertTrue(try Data(contentsOf: record) == before, "empty key read changed its record")
        }
    }

    private func assertPresentLocation(_ read: LocationRead) throws {
        try withFixture { fixture in
            let expected = fixture.location()
            switch read {
            case .localConnect, .snapshotConnect:
                try fixture.local.setConnectLocation(expected)
            case .localDefault, .snapshotDefault:
                try fixture.local.setDefaultLocation(expected)
            }
            let record = fixture.record(read.recordName)
            let before = try Data(contentsOf: record)
            let actual = try XCTUnwrap(read.load(fixture))
            XCTAssertTrue(actual.equals(expected), "loaded location changed")
            XCTAssertEqual(actual.name, expected.name)
            XCTAssertTrue(try Data(contentsOf: record) == before, "location read changed its record")
        }
    }

    private func assertInvalidLocation(_ read: LocationRead, json: String) throws {
        try withFixture { fixture in
            let record = fixture.record(read.recordName)
            let before = try fixture.write(json, to: record)
            assertStorageError("decode saved location") { try read.load(fixture) }
            XCTAssertTrue(try Data(contentsOf: record) == before, "failed location read changed its record")
        }
    }

    private func assertUnreadableLocation(_ read: LocationRead) throws {
        try withFixture { fixture in
            let record = fixture.record(read.recordName)
            let target = try fixture.makeDanglingSymlink(at: record)
            assertStorageError("resolve saved location") { try read.load(fixture) }
            XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: record.path) == target.path,
                          "failed location read changed its symlink")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    private func assertStorageError<Value>(_ stage: String, _ load: () throws -> Value) {
        XCTAssertThrowsError(try load()) { error in
            let nativeError = error as NSError
            XCTAssertEqual(nativeError.domain, "go")
            XCTAssertEqual(nativeError.code, 1)
            XCTAssertEqual(nativeError.localizedDescription, stage)
        }
    }

    private enum LocationRead {
        case localConnect
        case localDefault
        case snapshotConnect
        case snapshotDefault

        var recordName: String {
            switch self {
            case .localConnect, .snapshotConnect: return ".connect_location"
            case .localDefault, .snapshotDefault: return ".default_location"
            }
        }

        // The checked read throws before its error-free getter exposes the
        // optional value. Neither absence nor failure is reinterpreted here.
        func load(_ fixture: Fixture) throws -> SdkConnectLocation? {
            switch self {
            case .localConnect:
                return try fixture.local.readConnectLocation().getLocation()
            case .localDefault:
                return try fixture.local.readDefaultLocation().getLocation()
            case .snapshotConnect:
                let snapshot = try fixture.space.getAuthStateSnapshot()
                return try snapshot.readConnectLocation().getLocation()
            case .snapshotDefault:
                let snapshot = try fixture.space.getAuthStateSnapshot()
                return try snapshot.readDefaultLocation().getLocation()
            }
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try body(fixture)
    }

    private enum FixtureError: Error { case missingStore }

    private final class Fixture {
        let directory: URL
        let manager: SdkNetworkSpaceManager
        let space: SdkNetworkSpace
        let local: SdkLocalState
        let storage: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "native-optional-storage-" + UUID().uuidString, isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            var created: SdkNetworkSpaceManager?
            do {
                let manager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
                created = manager
                let values = SdkNetworkSpaceValues()
                values.apiUrl = "http://127.0.0.1:1"
                values.platformUrl = "ws://127.0.0.1:1"
                let key = try XCTUnwrap(SdkNewNetworkSpaceKey("native-optional-storage.test", "test"))
                let space = try XCTUnwrap(manager.updateNetworkSpaceValues(key, values: values))
                let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
                // Match the manager's host/env scope and LocalState's .by
                // directory, without seeding an auth token or creating a device.
                let storage = directory.appendingPathComponent("network_spaces", isDirectory: true)
                    .appendingPathComponent("native-optional-storage.test", isDirectory: true)
                    .appendingPathComponent("test", isDirectory: true)
                    .appendingPathComponent(".by", isDirectory: true)
                guard try storage.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    XCTFail("manager did not create the expected local store")
                    throw FixtureError.missingStore
                }
                self.directory = directory
                self.manager = manager
                self.space = space
                self.local = local
                self.storage = storage
            } catch {
                created?.close()
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    XCTFail("optional storage fixture setup cleanup failed")
                }
                throw error
            }
        }

        func location() -> SdkConnectLocation {
            let id = SdkConnectLocationId()
            id.bestAvailable = true
            let location = SdkConnectLocation()
            location.connectLocationId = id
            location.name = "healthy optional storage control"
            return location
        }

        func record(_ name: String) -> URL {
            storage.appendingPathComponent(name)
        }

        func write(_ json: String, to record: URL) throws -> Data {
            let data = Data(json.utf8)
            try data.write(to: record, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            return data
        }

        // A dangling link reaches the checked loader's resolve/read failure
        // path even when a test executor can bypass file permission bits.
        func makeDanglingSymlink(at record: URL) throws -> URL {
            let target = storage.appendingPathComponent("missing-target")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            try FileManager.default.createSymbolicLink(at: record, withDestinationURL: target)
            return target
        }

        func cleanUp() {
            manager.close()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                XCTFail("optional storage fixture cleanup failed")
            }
        }
    }
}
