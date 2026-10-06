import Foundation
import URnetworkSdk
import XCTest

// Each network starts fresh (owner decision 2026-10-05): a sign-out the
// tunnel process missed (it was not running) leaves the signed-out network's
// auth and device identity in the extension's own store, and the next start
// for another network resets that store. The conditional reset keeps the
// identity file, so the start clears it too unless the stored and configured
// clients name the same network. The store is the real SDK's; no
// NetworkExtension, keychain or remote service.
final class TunnelFreshNetworkIdentityTests: XCTestCase {
    private static let networkA = "00000000-0000-0000-0000-00000000000a"
    private static let networkB = "00000000-0000-0000-0000-00000000000b"

    func testAResetForAnotherNetworkClearsTheStoredIdentity() throws {
        var events: [String] = []
        let _: String = try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-b",
            readAuthIdentity: {
                TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a", sameNetwork: false)
            },
            clearStaleState: { events.append("reset") },
            clearStaleIdentity: { events.append("identity") },
            selectClientJwt: { events.append("select"); return "client-b" },
            startSession: { events.append("construct"); return $0 }
        )
        XCTAssertEqual(events, ["reset", "identity", "select", "construct"])
    }

    func testAResetForTheSameNetworkKeepsTheStoredIdentity() throws {
        var events: [String] = []
        let _: String = try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-a2",
            readAuthIdentity: {
                TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a", sameNetwork: true)
            },
            clearStaleState: { events.append("reset") },
            clearStaleIdentity: { events.append("identity") },
            selectClientJwt: { events.append("select"); return "client-a" },
            startSession: { events.append("construct"); return $0 }
        )
        XCTAssertEqual(events, ["reset", "select", "construct"])
    }

    func testAStartWithoutAResetClearsNoIdentity() throws {
        var events: [String] = []
        let _: String = try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-a",
            readAuthIdentity: {
                TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a", sameNetwork: false)
            },
            clearStaleState: { events.append("reset") },
            clearStaleIdentity: { events.append("identity") },
            selectClientJwt: { events.append("select"); return "client-a" },
            startSession: { events.append("construct"); return $0 }
        )
        XCTAssertEqual(events, ["select", "construct"])
    }

    // The production closures against the real store: network A's identity
    // does not survive the start of network B, and network A's own new
    // instance keeps it.
    func testRealResetForAnotherNetworkStartsWithoutTheStoredIdentity() throws {
        for (configuredNetwork, keepsIdentity) in [(Self.networkB, false), (Self.networkA, true)] {
            try withNetworkSpace { space in
                let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
                let storedInstance = try XCTUnwrap(SdkNewId())
                try local.setByClientJwt(clientJwt(networkId: Self.networkA))
                try local.setInstanceId(storedInstance)
                let seed = Data(repeating: 9, count: 32)
                try local.setDeviceLocalKeyMaterial(XCTUnwrap(SdkNewDeviceLocalKeyMaterial(seed, nil, nil)))
                let configuredInstance = try XCTUnwrap(SdkNewId())
                var observed: SdkLocalAuthStateSnapshot?
                var keyMaterial: SdkDeviceLocalKeyMaterial?
                let started: Bool = try prepareTunnelLocalAuthState(
                    configuredInstanceId: configuredInstance.string(),
                    readAuthIdentity: {
                        let snapshot = try XCTUnwrap(space.getAuthStateSnapshot())
                        observed = snapshot
                        return TunnelLocalAuthIdentitySnapshot(
                            isEmpty: snapshot.getEmpty(),
                            instanceId: snapshot.getInstanceId()?.string(),
                            sameNetwork: configuredNetwork == Self.networkA
                        )
                    },
                    clearStaleState: {
                        let result = try space.resetLocalStateIfCurrent(XCTUnwrap(observed))
                        XCTAssertTrue(result.getReset())
                        keyMaterial = result.getDeviceLocalKeyMaterial()
                    },
                    clearStaleIdentity: {
                        try local.logout()
                        keyMaterial = nil
                    },
                    selectClientJwt: { "unused" },
                    startSession: { _ in true }
                )
                XCTAssertTrue(started)
                let stored = try local.readDeviceLocalKeyMaterial().getKeyMaterial()
                if keepsIdentity {
                    XCTAssertTrue(keyMaterial?.getClientKeySeed() == seed, "network A lost its identity")
                    XCTAssertTrue(stored?.getClientKeySeed() == seed, "network A's stored identity was removed")
                } else {
                    XCTAssertNil(keyMaterial, "network B's device was handed network A's identity")
                    XCTAssertNil(stored, "network A's identity stayed in the store for network B")
                }
            }
        }
    }

    // The tunnel computes the rule from both clients' network claims and
    // clears the reset store's identity file itself.
    func testTheTunnelStartWiresTheRule() throws {
        let provider = try String(
            contentsOf: Self.appRoot.appendingPathComponent("extension/PacketTunnelProvider.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(provider.range(of: "device = try prepareTunnelLocalAuthState("))
        let call = provider[start.lowerBound...]
        let needles = [
            "let storedNetworkId = storedOwner?.networkId",
            "sameNetwork: storedNetworkId != nil && storedNetworkId == configuredOwner?.networkId",
            "clearStaleState: {",
            "networkSpace.resetLocalStateIfCurrent(initialAuthSnapshot)",
            "clearStaleIdentity: {",
            "try localState.logout()",
            "keyMaterial = nil",
            "selectClientJwt: {",
        ]
        var from = call.startIndex
        for needle in needles {
            let found = call.range(of: needle, range: from..<call.endIndex)
            XCTAssertNotNil(found, "the tunnel start does not run `\(needle)` in order")
            if let found { from = found.upperBound }
        }
    }

    // …/apple/app/networkTests/TunnelFreshNetworkIdentityTests.swift -> …/apple/app
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    // A synthetic unsigned client credential of the server's shape.
    private func clientJwt(networkId: String) throws -> String {
        let encode: (Data) -> String = {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "client_id": "00000000-0000-0000-0000-000000000001",
            "device_id": "00000000-0000-0000-0000-000000000002",
            "network_id": networkId,
            "exp": Int64(2_000_000_000),
        ] as [String: Any])
        return encode(header) + "." + encode(payload) + "."
    }

    // A fresh manager with loopback endpoints only, removed afterwards.
    private func withNetworkSpace(_ body: (SdkNetworkSpace) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tunnel-fresh-network-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        defer {
            manager.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try XCTUnwrap(SdkNewNetworkSpaceKey("fresh-network.example", "test"))
        let space = try XCTUnwrap(manager.updateNetworkSpaceValues(key, values: values))
        try body(space)
    }
}
