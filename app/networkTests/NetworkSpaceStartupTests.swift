//
//  NetworkSpaceStartupTests.swift
//  networkTests
//
//  The launch sequence that prepares the bundled network space, run against
//  the real SDK in a private storage directory (no Keychain, network or
//  NetworkExtension access).
//
//  The operator stays bringyour.com. Builds before that decision bundled the
//  official space under key host ur.network with bringyour.com as the
//  migration host, so an existing install keeps its credentials and settings
//  under network_spaces/ur.network/main. The bundled key is now bringyour.com
//  with no migration host, and the one thing that keeps those installs signed
//  in is the order of `NetworkSpaceStartup.prepareBundledNetworkSpace`: the
//  legacy key is moved BEFORE the bundled key is created. These cases pin the
//  fresh install, the legacy install, the launch after it, a legacy install
//  that chose a custom server, and the control that shows what the wrong order
//  would do.
//

import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

final class NetworkSpaceStartupTests: XCTestCase {

    private static let marker = "device_state_marker"
    private static let markerContents = "signed-in state"

    private var directory: URL!
    private var openManagers: [SdkNetworkSpaceManager] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkSpaceStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        openManagers.forEach { $0.close() }
        openManagers.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: fixtures

    private func openManager() throws -> SdkNetworkSpaceManager {
        let manager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        openManagers.append(manager)
        return manager
    }

    private func closeManager(_ manager: SdkNetworkSpaceManager) {
        manager.close()
        openManagers.removeAll { $0 === manager }
    }

    private func key(_ hostName: String) throws -> SdkNetworkSpaceKey {
        try XCTUnwrap(SdkNewNetworkSpaceKey(hostName, "main"))
    }

    private func storagePath(_ hostName: String) -> URL {
        directory
            .appendingPathComponent("network_spaces", isDirectory: true)
            .appendingPathComponent(hostName, isDirectory: true)
            .appendingPathComponent("main", isDirectory: true)
    }

    /// The bundled space exactly as the builds before the operator decision
    /// created it, active, with state in its storage directory.
    @discardableResult
    private func createLegacyBundledSpace(_ manager: SdkNetworkSpaceManager, active: Bool = true) throws -> SdkNetworkSpace {
        let values = SdkNetworkSpaceValues()
        values.bundled = true
        values.linkHostName = "ur.io"
        values.migrationHostName = "bringyour.com"
        values.wallet = NetworkConfig.wallet
        values.netExposeServerIps = true
        values.netExposeServerHostNames = true
        let legacy = try XCTUnwrap(manager.updateNetworkSpaceValues(try key("ur.network"), values: values))
        if active {
            manager.setActiveNetworkSpace(legacy)
        }
        let legacyStorage = storagePath("ur.network")
        try FileManager.default.createDirectory(at: legacyStorage, withIntermediateDirectories: true)
        try Self.markerContents.write(
            to: legacyStorage.appendingPathComponent(Self.marker),
            atomically: true, encoding: .utf8
        )
        return legacy
    }

    private func markerContents(under hostName: String) -> String? {
        try? String(contentsOf: storagePath(hostName).appendingPathComponent(Self.marker), encoding: .utf8)
    }

    private func assertOfficialBundledSpace(_ space: SdkNetworkSpace?, file: StaticString = #filePath, line: UInt = #line) {
        guard let space else {
            XCTFail("no bound network space", file: file, line: line)
            return
        }
        XCTAssertEqual(space.getHostName(), "bringyour.com", file: file, line: line)
        XCTAssertEqual(space.getEnvName(), "main", file: file, line: line)
        XCTAssertTrue(space.getBundled(), file: file, line: line)
        XCTAssertEqual(space.getMigrationHostName(), "", file: file, line: line)
        XCTAssertEqual(space.getLinkHostName(), "ur.io", file: file, line: line)
        XCTAssertEqual(space.getApiUrl(), "https://api.bringyour.com", file: file, line: line)
        XCTAssertEqual(space.getPlatformUrl(), "wss://connect.bringyour.com", file: file, line: line)
    }

    // MARK: cases

    func testFreshInstallBindsTheOfficialSpaceWithNoMigrationHost() throws {
        let manager = try openManager()

        let bound = NetworkSpaceStartup.prepareBundledNetworkSpace(manager)

        assertOfficialBundledSpace(bound)
        XCTAssertEqual(manager.getActiveNetworkSpace()?.getHostName(), "bringyour.com")
        XCTAssertNil(manager.getNetworkSpace(try key("ur.network")), "a fresh install never creates the legacy key")
        // nothing to move on a fresh install, and the destination now exists
        XCTAssertFalse(NetworkSpaceStartup.migrateLegacyBundledNetworkSpace(manager))
    }

    func testLegacyInstallIsMovedToTheOfficialKeyAndStaysSignedIn() throws {
        let setup = try openManager()
        try createLegacyBundledSpace(setup)
        closeManager(setup)

        // the launch of the first build that bundles bringyour.com
        let manager = try openManager()
        let bound = NetworkSpaceStartup.prepareBundledNetworkSpace(manager)

        assertOfficialBundledSpace(bound)
        XCTAssertEqual(manager.getActiveNetworkSpace()?.getHostName(), "bringyour.com")
        XCTAssertNil(manager.getNetworkSpace(try key("ur.network")), "the legacy key must be gone, not left beside the new one")
        XCTAssertEqual(manager.getNetworkSpaces()?.len(), 1)
        // the state moved with the space: this is what keeps the install signed in
        XCTAssertEqual(markerContents(under: "bringyour.com"), Self.markerContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storagePath("ur.network").path))
    }

    func testLaunchAfterTheMigrationIsANoop() throws {
        let setup = try openManager()
        try createLegacyBundledSpace(setup)
        closeManager(setup)

        let first = try openManager()
        _ = NetworkSpaceStartup.prepareBundledNetworkSpace(first)
        closeManager(first)

        let second = try openManager()
        XCTAssertFalse(NetworkSpaceStartup.migrateLegacyBundledNetworkSpace(second), "idempotent: nothing left to move")
        let bound = NetworkSpaceStartup.prepareBundledNetworkSpace(second)

        assertOfficialBundledSpace(bound)
        XCTAssertEqual(second.getActiveNetworkSpace()?.getHostName(), "bringyour.com")
        XCTAssertEqual(second.getNetworkSpaces()?.len(), 1)
        XCTAssertEqual(markerContents(under: "bringyour.com"), Self.markerContents)
    }

    func testLegacyInstallOnACustomServerKeepsThatServerActive() throws {
        let setup = try openManager()
        try createLegacyBundledSpace(setup, active: false)
        let customValues = SdkNetworkSpaceValues()
        customValues.apiUrl = "https://api.custom.example"
        customValues.platformUrl = "wss://connect.custom.example"
        let custom = try XCTUnwrap(setup.updateNetworkSpaceValues(try key("custom.example"), values: customValues))
        setup.setActiveNetworkSpace(custom)
        closeManager(setup)

        let manager = try openManager()
        let bound = NetworkSpaceStartup.prepareBundledNetworkSpace(manager)

        // the user's choice is honoured (NetworkSpaceSelection), and the
        // bundled space still moved to its new key underneath
        XCTAssertEqual(bound?.getHostName(), "custom.example")
        XCTAssertEqual(manager.getActiveNetworkSpace()?.getHostName(), "custom.example")
        assertOfficialBundledSpace(manager.getNetworkSpace(try key("bringyour.com")))
        XCTAssertNil(manager.getNetworkSpace(try key("ur.network")))
        XCTAssertEqual(markerContents(under: "bringyour.com"), Self.markerContents)
    }

    /// The control for the ordering contract: creating the bundled key before
    /// the migration leaves the SDK nothing it may move (the destination is
    /// taken), so the legacy space and the signed-in state are stranded under
    /// the old key. `prepareBundledNetworkSpace` must never reach this state.
    func testCreatingTheBundledKeyFirstWouldStrandTheLegacyInstall() throws {
        let setup = try openManager()
        try createLegacyBundledSpace(setup)
        closeManager(setup)

        let manager = try openManager()
        let values = SdkNetworkSpaceValues()
        values.bundled = true
        _ = manager.updateNetworkSpaceValues(try key("bringyour.com"), values: values)

        XCTAssertFalse(NetworkSpaceStartup.migrateLegacyBundledNetworkSpace(manager))
        XCTAssertNotNil(manager.getNetworkSpace(try key("ur.network")))
        XCTAssertEqual(manager.getActiveNetworkSpace()?.getHostName(), "ur.network")
        XCTAssertNil(markerContents(under: "bringyour.com"))
        XCTAssertEqual(markerContents(under: "ur.network"), Self.markerContents)
    }
}
