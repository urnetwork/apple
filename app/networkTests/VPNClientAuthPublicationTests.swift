import URnetworkSdk
import XCTest
@testable import URnetwork

private final class VPNTestingClientAuthSource: VPNClientAuthSource {
    let clientJwt: String
    let instanceId: SdkId?

    init(clientJwt: String, instanceId: SdkId?) {
        self.clientJwt = clientJwt
        self.instanceId = instanceId
    }

    func getClientJwt() -> String { clientJwt }
    func getInstanceId() -> SdkId? { instanceId }
}

// SDK getter semantics have actual-constructor Go regressions. These consumer
// tests supply only the narrow client/instance interface and an in-memory sink:
// no default RPC endpoint, Keychain, profile save, or NetworkExtension startup.
@MainActor
final class VPNClientAuthPublicationTests: XCTestCase {
    func testSeedUsesConstructedClientRatherThanPreliminaryInput() throws {
        let preliminaryClient = "client-before-construction"
        let publishedClient = "client-selected-by-constructor"
        let instanceId = try XCTUnwrap(SdkNewId())
        let device = VPNTestingClientAuthSource(clientJwt: publishedClient, instanceId: instanceId)
        var savedClient: String?
        var savedInstance: String?
        VPNManager.seedCurrentTunnelJwtIfMissing(device: device) { clientJwt, instance in
            savedClient = clientJwt
            savedInstance = instance
        }
        XCTAssertEqual(savedClient, publishedClient)
        XCTAssertNotEqual(savedClient, preliminaryClient)
        XCTAssertEqual(savedInstance, instanceId.string())
    }

    func testMissingPublishedClientCannotSeedFromAnotherCredential() throws {
        let device = VPNTestingClientAuthSource(clientJwt: "", instanceId: try XCTUnwrap(SdkNewId()))
        var writes = 0
        VPNManager.seedCurrentTunnelJwtIfMissing(device: device) { _, _ in writes += 1 }
        XCTAssertEqual(writes, 0)
    }

    func testMissingInstanceCannotPublishClient() {
        let device = VPNTestingClientAuthSource(clientJwt: "published-client", instanceId: nil)
        var writes = 0
        VPNManager.seedCurrentTunnelJwtIfMissing(device: device) { _, _ in writes += 1 }
        XCTAssertEqual(writes, 0)
    }
}
