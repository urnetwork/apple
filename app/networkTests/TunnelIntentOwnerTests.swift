import Foundation
import XCTest
@testable import URnetwork

final class TunnelIntentOwnerTests: XCTestCase {
    func testExistingIntentRecordRoundTripsScopedOwnerWithoutCredentials() throws {
        try withDefaults { defaults in
            let owner = try XCTUnwrap(makeOwner(network: networkA))
            let recorded = TunnelIntentStore.record(
                connect: true, source: TunnelIntentStore.sourceApp, owner: owner,
                at: Date(timeIntervalSince1970: 100), in: defaults
            )
            let restored = try XCTUnwrap(TunnelIntentStore.loadChecked(from: defaults))
            XCTAssertEqual(restored, recorded)
            XCTAssertTrue(restored.applies(to: owner))
            let bytes = try XCTUnwrap(defaults.data(forKey: TunnelIntentStore.key))
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("private-token-marker"))
            XCTAssertFalse(text.contains("private-space-secret"))
            XCTAssertFalse(text.contains("by_jwt"))
        }
    }

    func testLegacyConnectDoesNotAuthorizeFreshDestination() throws {
        try withDefaults { defaults in
            let data = Data("{\"connect\":true,\"changedAt\":100,\"source\":\"app\"}".utf8)
            defaults.set(data, forKey: TunnelIntentStore.key)
            let intent = try XCTUnwrap(TunnelIntentStore.loadChecked(from: defaults))
            XCTAssertNil(intent.owner)
            XCTAssertFalse(intent.applies(to: makeOwner(network: networkA)))
        }
    }

    func testLegacyDisconnectRemainsSafeVeto() throws {
        try withDefaults { defaults in
            defaults.set(Data("{\"connect\":false,\"changedAt\":100,\"source\":\"system\"}".utf8), forKey: TunnelIntentStore.key)
            let intent = try XCTUnwrap(TunnelIntentStore.loadChecked(from: defaults))
            XCTAssertTrue(intent.applies(to: makeOwner(network: networkA)))
            XCTAssertTrue(intent.applies(to: nil))
        }
    }

    func testOmittedOrZeroNetworkClaimBecomingKnownKeepsSameOwner() throws {
        let unknown = try XCTUnwrap(makeOwner(network: nil))
        let zero = try XCTUnwrap(makeOwner(network: "00000000-0000-0000-0000-000000000000"))
        let known = try XCTUnwrap(makeOwner(network: networkA))
        XCTAssertTrue(unknown.matches(known))
        XCTAssertTrue(known.matches(unknown))
        XCTAssertTrue(zero.matches(known))
    }

    func testKnownAccountConflictRejectsConnectAndDisconnectFromOldOwner() throws {
        let old = try XCTUnwrap(makeOwner(network: networkA))
        let current = try XCTUnwrap(makeOwner(network: networkB))
        for connect in [true, false] {
            let intent = TunnelIntent(connect: connect, changedAt: Date(), source: "app", owner: old)
            XCTAssertFalse(intent.applies(to: current))
        }
    }

    func testClientInstanceAndNetworkSpaceConflictsCannotBeRenewal() throws {
        let owner = try XCTUnwrap(makeOwner(network: nil))
        let otherClient = try XCTUnwrap(makeOwner(network: nil, client: networkB))
        let otherInstance = try XCTUnwrap(makeOwner(network: nil, instance: networkB))
        let otherSpace = try XCTUnwrap(makeOwner(network: nil, host: "other.test"))
        XCTAssertFalse(owner.matches(otherClient))
        XCTAssertFalse(owner.matches(otherInstance))
        XCTAssertFalse(owner.matches(otherSpace))
    }

    func testKnownUserConflictIsNotHiddenByMatchingNetwork() throws {
        let first = try XCTUnwrap(makeOwner(network: networkA, user: networkA))
        let other = try XCTUnwrap(makeOwner(network: networkA, user: networkB))
        XCTAssertFalse(first.matches(other))
    }

    func testKnownDeviceConflictIsNotHiddenByMatchingClientAndNetwork() throws {
        let unknown = try XCTUnwrap(makeOwner(network: networkA))
        let first = try XCTUnwrap(makeOwner(network: networkA, device: networkA))
        let other = try XCTUnwrap(makeOwner(network: networkA, device: networkB))
        XCTAssertTrue(unknown.matches(first))
        XCTAssertFalse(first.matches(other))
    }

    func testUnknownOwnerCannotAuthorizeScopedConnect() throws {
        let intent = TunnelIntent(connect: true, changedAt: Date(), source: "app", owner: try XCTUnwrap(makeOwner(network: nil)))
        XCTAssertFalse(intent.applies(to: nil))
    }

    func testLateOldOwnerRecordCannotBecomeCurrentThroughNewerTimestamp() throws {
        let old = try XCTUnwrap(makeOwner(network: networkA))
        let current = try XCTUnwrap(makeOwner(network: networkB))
        let late = TunnelIntent(connect: true, changedAt: Date(timeIntervalSince1970: 10_000), source: "control", owner: old)
        XCTAssertTrue(TunnelIntentStore.supersedes(late, localChangedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(late.applies(to: current))
    }

    func testMalformedSharedRecordIsNotAnAbsentRecord() throws {
        try withDefaults { defaults in
            XCTAssertNil(try TunnelIntentStore.loadChecked(from: defaults))
            defaults.set(Data("private-marker-invalid-json".utf8), forKey: TunnelIntentStore.key)
            XCTAssertThrowsError(try TunnelIntentStore.loadChecked(from: defaults))
            defaults.set("wrong-type", forKey: TunnelIntentStore.key)
            XCTAssertThrowsError(try TunnelIntentStore.loadChecked(from: defaults))
        }
        XCTAssertThrowsError(try TunnelIntentStore.loadChecked(from: nil))
    }

    func testUnreadableThenOldScopedConnectRecordCannotUndoLiveDisconnect() throws {
        try withDefaults { defaults in
            let owner = try XCTUnwrap(makeOwner(network: networkA))
            let old = TunnelIntentStore.record(
                connect: true, source: TunnelIntentStore.sourceApp, owner: owner,
                at: Date(timeIntervalSince1970: 100), in: defaults
            )
            var observed: TunnelIntent? = old
            var disconnectedAt: Date?
            defaults.set(Data("private-read-failure".utf8), forKey: TunnelIntentStore.key)
            XCTAssertThrowsError(try recordTunnelLiveDisconnect(
                at: Date(timeIntervalSince1970: 200),
                readIntent: { try TunnelIntentStore.loadChecked(from: defaults) },
                liveDisconnectAt: &disconnectedAt, observedIntent: &observed
            ))
            XCTAssertEqual(observed, old)
            TunnelIntentStore.record(connect: true, source: old.source, owner: owner, at: old.changedAt, in: defaults)
            let readable = try XCTUnwrap(TunnelIntentStore.loadChecked(from: defaults))
            XCTAssertTrue(readable.applies(to: owner))
            XCTAssertFalse(tunnelConnectIntentIsNewer(changedAt: readable.changedAt, liveDisconnectAt: disconnectedAt))
            let newer = TunnelIntentStore.record(
                connect: true, source: old.source, owner: owner,
                at: Date(timeIntervalSince1970: 201), in: defaults
            )
            XCTAssertTrue(newer.applies(to: owner))
            XCTAssertTrue(tunnelConnectIntentIsNewer(changedAt: newer.changedAt, liveDisconnectAt: disconnectedAt))
        }
    }

    private let networkA = "00000000-0000-0000-0000-000000000004"
    private let networkB = "00000000-0000-0000-0000-000000000005"

    private func makeOwner(
        network: String?,
        client: String = "00000000-0000-0000-0000-000000000001",
        instance: String = "00000000-0000-0000-0000-000000000002",
        host: String = "owner.test",
        user: String? = nil,
        device: String? = nil
    ) -> TunnelIntentOwner? {
        var claims = ["client_id": client, "marker": "private-token-marker"]
        claims["network_id"] = network
        claims["user_id"] = user
        claims["device_id"] = device
        guard let bytes = try? JSONSerialization.data(withJSONObject: claims),
              let space = try? JSONSerialization.data(withJSONObject: [
                "key": ["host_name": host, "env_name": ""],
                "values": ["env_secret": "private-space-secret"]
              ]) else { return nil }
        let payload = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return TunnelIntentOwner.make(
            instanceId: instance, clientJwt: "header." + payload + ".signature",
            networkSpaceJson: String(decoding: space, as: UTF8.self)
        )
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "network.ur.intent-owner-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
