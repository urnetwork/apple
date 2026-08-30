import Testing
import URnetworkSdk
@testable import URnetwork

struct NetworkPeerItemTests {

    @Test func exactPeerAcceptanceIdentifierUsesStableClientID() throws {
        let clientID = try #require(SdkNewId())
        let peer = NetworkPeerItem(
            clientId: clientID,
            deviceName: "acceptance provider",
            deviceSpec: "macos/arm64",
            provideEnabled: true
        )

        #expect(peer.acceptanceIdentifier == "acceptance.peer.\(clientID.idStr)")
        let location = peer.toConnectLocation()
        #expect(location.networkPeer)
        #expect(location.connectLocationId?.clientId?.idStr == clientID.idStr)
    }
}
