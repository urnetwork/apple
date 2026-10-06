import Foundation
import URnetworkSdk
import XCTest
@testable import URnetwork

// Each network starts fresh (owner decision 2026-10-05): the explicit sign-out
// clears the credential the app's api attaches to its calls, so the next
// sign-in's calls (auth login, network create, the wallet challenge) never
// carry the signed-out network's token. The manager runs in the hardware lane
// (no keychain, no VPN profiles) over a real SDK network space with loopback
// endpoints only.
@MainActor
final class DeviceManagerLogoutCredentialTests: XCTestCase {
    func testLogoutClearsTheApiCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "logout-credential-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spaceManager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        defer {
            spaceManager.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try XCTUnwrap(SdkNewNetworkSpaceKey("logout-credential.example", "test"))
        let space = try XCTUnwrap(spaceManager.updateNetworkSpaceValues(key, values: values))

        let manager = DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
        manager.setActiveNetworkSpace(space)
        manager.api?.setByJwt("admin-credential-of-network-a")
        XCTAssertEqual(manager.api?.getByJwt(), "admin-credential-of-network-a")

        manager.logout()

        XCTAssertEqual(space.getApi()?.getByJwt(), "", "the signed-out network's credential stayed on the api")
    }
}
