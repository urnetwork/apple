import Foundation
import URnetworkSdk
import XCTest

final class TunnelLocalStateIdentityTests: XCTestCase {
    func testNSErrorBridgeRejectsReturnedValueWhenCallAlsoReportsFailure() {
        let error = NSError(domain: "TunnelBindingFixture", code: 23)
        XCTAssertThrowsError(try checkedTunnelSdkValue { output in
            output?.pointee = error
            return "must-not-be-adopted"
        }) { XCTAssertEqual(($0 as NSError).code, 23) }
    }

    func testNSErrorBridgeReturnsSuccessfulValueAndDoesNotReusePriorError() throws {
        XCTAssertThrowsError(try checkedTunnelSdkValue { output in
            output?.pointee = NSError(domain: "TunnelBindingFixture", code: 23)
            return "failed"
        })
        XCTAssertEqual(try checkedTunnelSdkValue { output in
            XCTAssertNil(output?.pointee)
            return "accepted"
        }, "accepted")
    }
    func testNewerProfileWinsReadOnlySharedHistorySelection() {
        let profile = TunnelStartupJwtCandidate(
            account: "profile", byJwt: "client-profile-new",
            issuedAt: 20, expiresAt: 200
        )
        let history = TunnelStartupJwtCandidate(
            account: "history", byJwt: "client-history-old",
            issuedAt: 10, expiresAt: 200
        )
        XCTAssertEqual(selectTunnelStartupClient(
            configured: profile, persisted: [history], now: 100
        ), profile.byJwt)
    }

    func testRefreshedHistoryWinsOverOlderProfile() {
        let profile = TunnelStartupJwtCandidate(
            account: "profile", byJwt: "client-profile-old",
            issuedAt: 10, expiresAt: 200
        )
        let history = TunnelStartupJwtCandidate(
            account: "history", byJwt: "client-history-new",
            issuedAt: 20, expiresAt: 200
        )
        XCTAssertEqual(selectTunnelStartupClient(
            configured: profile, persisted: [history], now: 100
        ), history.byJwt)
    }

    func testExpiredProfileCannotDisplaceUnexpiredHistory() {
        let profile = TunnelStartupJwtCandidate(
            account: "profile", byJwt: "client-expired",
            issuedAt: 20, expiresAt: 99
        )
        let history = TunnelStartupJwtCandidate(
            account: "history", byJwt: "client-valid",
            issuedAt: 10, expiresAt: 200
        )
        XCTAssertEqual(selectTunnelStartupClient(
            configured: profile, persisted: [history], now: 100
        ), history.byJwt)
    }

    func testSharedSelectionRetainsExistingEqualDateAccountTieBreak() {
        let profile = TunnelStartupJwtCandidate(
            account: "account-a", byJwt: "client-a",
            issuedAt: 10, expiresAt: 200
        )
        let history = TunnelStartupJwtCandidate(
            account: "account-z", byJwt: "client-z",
            issuedAt: 10, expiresAt: 200
        )
        XCTAssertEqual(selectTunnelStartupClient(
            configured: profile, persisted: [history], now: 100
        ), history.byJwt)
        XCTAssertEqual(selectTunnelStartupClient(
            configured: history, persisted: [profile], now: 100
        ), history.byJwt)
    }

    func testSharedSelectionRetainsExistingUndatedPreference() {
        let profile = TunnelStartupJwtCandidate(
            account: "profile", byJwt: "client-undated",
            issuedAt: nil, expiresAt: nil
        )
        let history = TunnelStartupJwtCandidate(
            account: "history", byJwt: "client-dated",
            issuedAt: 10, expiresAt: 200
        )
        XCTAssertEqual(selectTunnelStartupClient(
            configured: profile, persisted: [history], now: 100
        ), history.byJwt)
    }

    func testConstructorFailureCannotReachRpcOrRewriteHistory() {
        let originalHistory = Data("existing-history-client".utf8)
        var history = originalHistory
        var events: [String] = []
        func start() throws {
            let session: String = try prepareTunnelLocalAuthState(
                configuredInstanceId: "instance-a",
                readAuthIdentity: {
                    events.append("read")
                    return TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a")
                },
                clearStaleState: { events.append("reset") },
                selectClientJwt: { events.append("select"); return "preliminary-client" },
                startSession: { _ in
                    events.append("construct")
                    throw TunnelLocalAuthIdentityError.unavailable
                }
            )
            try finishTunnelLocalAuthSession(
                configureRpc: { events.append("rpc") },
                publishedClientJwt: { session },
                publishClient: { history = Data($0.utf8) }
            )
        }
        XCTAssertThrowsError(try start())
        XCTAssertEqual(events, ["read", "select", "construct"])
        XCTAssertEqual(history, originalHistory)
    }

    func testRpcFailureCannotPublishClientOrRewriteHistory() {
        let originalHistory = Data("existing-history-client".utf8)
        var history = originalHistory
        var reads = 0
        var events: [String] = []
        func start() throws {
            let startupCleanup = TunnelStartupCleanup {
                events.append("device")
                events.append("manager")
            }
            // Match the production RPC failure path's already-owned cleanup.
            defer { startupCleanup.cleanUpNow() }
            try finishTunnelLocalAuthSession(
                configureRpc: {
                    events.append("rpc")
                    throw TunnelLocalAuthIdentityError.unavailable
                },
                publishedClientJwt: { reads += 1; return "constructed-client" },
                publishClient: { history = Data($0.utf8) }
            )
        }
        XCTAssertThrowsError(try start())
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(history, originalHistory)
        XCTAssertEqual(events, ["rpc", "device", "manager"])
    }

    func testSuccessfulRpcPublishesOnlyConstructedClient() throws {
        let originalHistory = Data("existing-history-client".utf8)
        var history = originalHistory
        var writes = 0
        var rpcCalls = 0
        let deviceClient = try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-a",
            readAuthIdentity: {
                TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a")
            },
            clearStaleState: { XCTFail("same instance must not reset") },
            selectClientJwt: { "preliminary-client" },
            startSession: { preliminaryClient in
                XCTAssertEqual(preliminaryClient, "preliminary-client")
                return "constructed-client-newer"
            }
        )
        XCTAssertEqual(history, originalHistory)
        try finishTunnelLocalAuthSession(
            configureRpc: { rpcCalls += 1 },
            publishedClientJwt: { deviceClient },
            publishClient: { writes += 1; history = Data($0.utf8) }
        )
        XCTAssertEqual(history, Data("constructed-client-newer".utf8))
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(rpcCalls, 1)
    }

    func testMissingPublishedClientCannotRewriteHistory() {
        let originalHistory = Data("existing-history-client".utf8)
        var history = originalHistory
        XCTAssertThrowsError(try finishTunnelLocalAuthSession(
            configureRpc: {},
            publishedClientJwt: { "" },
            publishClient: { history = Data($0.utf8) }
        ))
        XCTAssertEqual(history, originalHistory)
    }

    // Keep the original user test identities. Renewable JWT bytes no longer
    // participate in the stable-instance decision.
    func testRotatedJwtForSameInstancePreservesLocalState() throws {
        XCTAssertFalse(try tunnelLocalStateRequiresReset(
            snapshot: TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a"),
            configuredInstanceId: "instance-a"
        ))
    }

    func testDifferentInstanceResetsEvenWhenJwtMatches() throws {
        XCTAssertTrue(try tunnelLocalStateRequiresReset(
            snapshot: TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a"),
            configuredInstanceId: "instance-b"
        ))
    }

    // Historical name retained deliberately: the old expectation treated
    // unknown as different and erased state. An incomplete nonempty snapshot
    // must now abort rather than authorize a reset.
    func testMissingOrUnreadableInstanceResets() {
        for storedInstanceId in [nil, ""] as [String?] {
            XCTAssertThrowsError(try tunnelLocalStateRequiresReset(
                snapshot: TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: storedInstanceId),
                configuredInstanceId: "instance-a"
            ))
        }
    }

    // Historical name retained; an invalid configured identity cannot own a
    // destructive transition.
    func testMissingConfiguredInstanceResets() {
        XCTAssertThrowsError(try tunnelLocalStateRequiresReset(
            snapshot: TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a"),
            configuredInstanceId: ""
        ))
    }

    func testAbsentAuthDoesNotAuthorizeDestructiveReset() throws {
        XCTAssertFalse(try tunnelLocalStateRequiresReset(
            snapshot: TunnelLocalAuthIdentitySnapshot(isEmpty: true, instanceId: nil),
            configuredInstanceId: "instance-a"
        ))
    }

    func testReadFailurePreventsResetSelectionAndConstruction() {
        var events: [String] = []
        XCTAssertThrowsError(try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-a",
            readAuthIdentity: {
                events.append("read")
                throw TunnelLocalAuthIdentityError.unavailable
            },
            clearStaleState: { events.append("reset") },
            selectClientJwt: { events.append("select"); return "selected-client" },
            startSession: { _ in events.append("construct") }
        ))
        XCTAssertEqual(events, ["read"])
    }

    func testIncompleteRealAuthSnapshotCannotResetRoutingOrConstruct() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            let adminJwt = "separate-admin"
            try localState.setByJwt(adminJwt)
            try seedRoutingFixture(localState, instanceId: instanceId)
            let storedClientJwt = localState.getByClientJwt()
            try localState.setInstanceId(nil)
            var events: [String] = []
            XCTAssertThrowsError(try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    events.append("read")
                    let snapshot = try XCTUnwrap(localState.getAuthStateSnapshot())
                    XCTAssertFalse(snapshot.getEmpty())
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: {
                    events.append("reset")
                    try localState.logout()
                },
                selectClientJwt: { events.append("select"); return storedClientJwt },
                startSession: { _ in events.append("construct") }
            ))
            XCTAssertEqual(events, ["read"])
            XCTAssertEqual(localState.getByJwt(), adminJwt)
            XCTAssertEqual(localState.getByClientJwt(), storedClientJwt)
            XCTAssertNil(localState.getInstanceId())
            XCTAssertNotNil(localState.getConnectLocation())
            XCTAssertNotNil(localState.getDefaultLocation())
        }
    }

    func testMalformedRealAuthEnvelopeCannotAuthorizeReset() throws {
        try withNetworkSpaceDirectory { networkSpace, directory in
            let localState = try XCTUnwrap(networkSpace.getAsyncLocalState()?.getLocalState())
            let instanceId = try XCTUnwrap(SdkNewId())
            try seedRoutingFixture(localState, instanceId: instanceId)
            let envelope = try authEnvelope(in: directory)
            let malformed = Data("{incomplete-auth-envelope".utf8)
            try malformed.write(to: envelope, options: .atomic)
            let routingPaths = [".connect_location", ".default_location"].map {
                envelope.deletingLastPathComponent().appendingPathComponent($0)
            }
            let routingBefore = try routingPaths.map { try Data(contentsOf: $0) }
            let attributesBefore = try FileManager.default.attributesOfItem(atPath: envelope.path)
            XCTAssertEqual(attributesBefore[.type] as? FileAttributeType, .typeRegular)
            var events: [String] = []
            XCTAssertThrowsError(try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    events.append("read")
                    // XCTUnwrap records an assertion before rethrowing an
                    // expected SDK error from its autoclosure.
                    let snapshot = try localState.getAuthStateSnapshot()
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: { events.append("reset"); try localState.logout() },
                selectClientJwt: { events.append("select"); return "unused" },
                startSession: { _ in events.append("construct") }
            )) { error in
                let sdkError = error as NSError
                XCTAssertEqual(sdkError.domain, "go")
                XCTAssertEqual(sdkError.code, 1)
                XCTAssertEqual(sdkError.localizedDescription, "read auth snapshot")
            }
            XCTAssertEqual(events, ["read"])
            XCTAssertEqual(try Data(contentsOf: envelope), malformed)
            let attributesAfter = try FileManager.default.attributesOfItem(atPath: envelope.path)
            XCTAssertEqual(attributesAfter[.type] as? FileAttributeType, .typeRegular)
            XCTAssertTrue(try routingPaths.map { try Data(contentsOf: $0) } == routingBefore,
                          "failed auth read changed persisted routing")
            XCTAssertNotNil(localState.getConnectLocation())
            XCTAssertNotNil(localState.getDefaultLocation())
        }
    }

    func testNonRegularRealAuthEnvelopeCannotAuthorizeReset() throws {
        try withNetworkSpaceDirectory { networkSpace, directory in
            let localState = try XCTUnwrap(networkSpace.getAsyncLocalState()?.getLocalState())
            let instanceId = try XCTUnwrap(SdkNewId())
            try seedRoutingFixture(localState, instanceId: instanceId)
            let envelope = try authEnvelope(in: directory)
            // Only the synthetic envelope inside this test's private directory
            // is replaced; this deterministic type error works even as root.
            try FileManager.default.removeItem(at: envelope)
            try FileManager.default.createDirectory(at: envelope, withIntermediateDirectories: false)
            let routingPaths = [".connect_location", ".default_location"].map {
                envelope.deletingLastPathComponent().appendingPathComponent($0)
            }
            let routingBefore = try routingPaths.map { try Data(contentsOf: $0) }
            // The enumerated URL can retain the former file's cached type.
            // Inspect the actual path both before and after the checked read.
            let attributesBefore = try FileManager.default.attributesOfItem(atPath: envelope.path)
            XCTAssertEqual(attributesBefore[.type] as? FileAttributeType, .typeDirectory)
            var events: [String] = []
            XCTAssertThrowsError(try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    events.append("read")
                    let snapshot = try localState.getAuthStateSnapshot()
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: { events.append("reset"); try localState.logout() },
                selectClientJwt: { events.append("select"); return "unused" },
                startSession: { _ in events.append("construct") }
            )) { error in
                let sdkError = error as NSError
                XCTAssertEqual(sdkError.domain, "go")
                XCTAssertEqual(sdkError.code, 1)
                XCTAssertEqual(sdkError.localizedDescription, "read auth snapshot")
            }
            XCTAssertEqual(events, ["read"])
            let attributesAfter = try FileManager.default.attributesOfItem(atPath: envelope.path)
            XCTAssertEqual(attributesAfter[.type] as? FileAttributeType, .typeDirectory)
            XCTAssertTrue(try routingPaths.map { try Data(contentsOf: $0) } == routingBefore,
                          "failed auth read changed persisted routing")
            XCTAssertNotNil(localState.getConnectLocation())
            XCTAssertNotNil(localState.getDefaultLocation())
        }
    }

    func testIncompleteSnapshotPreventsResetSelectionAndConstruction() {
        var events: [String] = []
        XCTAssertThrowsError(try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-a",
            readAuthIdentity: {
                events.append("read")
                return TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: nil)
            },
            clearStaleState: { events.append("reset") },
            selectClientJwt: { events.append("select"); return "selected-client" },
            startSession: { _ in events.append("construct") }
        ))
        XCTAssertEqual(events, ["read"])
    }

    func testResetFailurePreventsSelectionAndConstruction() {
        var events: [String] = []
        XCTAssertThrowsError(try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-b",
            readAuthIdentity: {
                events.append("read")
                return TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a")
            },
            clearStaleState: {
                events.append("reset")
                throw TunnelLocalAuthIdentityError.unavailable
            },
            selectClientJwt: { events.append("select"); return "selected-client" },
            startSession: { _ in events.append("construct") }
        ))
        XCTAssertEqual(events, ["read", "reset"])
    }

    func testSelectionFailurePreventsConstruction() {
        var events: [String] = []
        XCTAssertThrowsError(try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-b",
            readAuthIdentity: {
                events.append("read")
                return TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a")
            },
            clearStaleState: { events.append("reset") },
            selectClientJwt: {
                events.append("select")
                throw TunnelLocalAuthIdentityError.unavailable
            },
            startSession: { _ in events.append("construct") }
        ))
        XCTAssertEqual(events, ["read", "reset", "select"])
    }

    func testAuthSnapshotIsReadOnceBeforeSelectionAndConstruction() throws {
        var reads = 0
        var events: [String] = []
        let result = try prepareTunnelLocalAuthState(
            configuredInstanceId: "instance-a",
            readAuthIdentity: {
                reads += 1
                events.append("read")
                return TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: "instance-a")
            },
            clearStaleState: { events.append("reset") },
            selectClientJwt: { events.append("select"); return "selected-client" },
            startSession: { selectedClientJwt in
                events.append("construct")
                XCTAssertEqual(selectedClientJwt, "selected-client")
                return 17
            }
        )
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(events, ["read", "select", "construct"])
        XCTAssertEqual(result, 17)
    }

    // This is the exact shipped reset/marker order against real SDK storage.
    // The control proves why a same-instance rotation loses its route and gives
    // the constructor a different generation from the subsequent startup reads.
    func testShippedJwtComparisonReproducesRoutingStateLoss() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            try seedRoutingFixture(localState, instanceId: instanceId)
            // Recreate the exact legacy extension markers, which misplaced the
            // client token in by_jwt and did not persist by_client_jwt.
            try localState.setByJwt("jwt-before-refresh")
            try localState.setInstanceId(instanceId)
            let storedJwt = localState.getByJwt()
            let storedInstanceId = localState.getInstanceId()?.string()
            let capturedLocation = localState.getConnectLocation()

            let configuredJwt = "jwt-after-refresh"
            let requiresReset = (!storedJwt.isEmpty && storedJwt != configuredJwt)
                || (storedInstanceId != nil && storedInstanceId != instanceId.string())
            XCTAssertTrue(requiresReset)
            if requiresReset {
                try localState.logout()
            }
            try localState.setByJwt(configuredJwt)
            try localState.setInstanceId(instanceId)

            XCTAssertNotNil(capturedLocation)
            XCTAssertNil(localState.getConnectLocation())
            XCTAssertNil(localState.getDefaultLocation())
            XCTAssertTrue(localState.getByClientJwt().isEmpty)
        }
    }

    // Runs the production startup transaction with the actual SDK auth and
    // routing store. Read-only selection retains the old complete generation
    // until the SDK constructor commits, without any destructive reset.
    func testRotatedJwtSelectionPreservesRoutingBeforeDeviceConstruction() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            try seedRoutingFixture(localState, instanceId: instanceId)
            let configuredJwt = try clientJwt(marker: "after", issuedAt: 1_800_000_001)
            var didConstruct = false
            var resetCount = 0
            try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    let snapshot = try XCTUnwrap(localState.getAuthStateSnapshot())
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: {
                    resetCount += 1
                    try localState.logout()
                },
                selectClientJwt: {
                    try checkedTunnelSdkValue {
                        localState.selectClientJwt(forInstance: configuredJwt, instanceId: instanceId, error: $0)
                    }
                },
                startSession: { selectedClientJwt in
                    didConstruct = true
                    XCTAssertTrue(localState.getByJwt().isEmpty)
                    XCTAssertEqual(selectedClientJwt, configuredJwt)
                    XCTAssertNotEqual(localState.getByClientJwt(), selectedClientJwt)
                    XCTAssertEqual(localState.getInstanceId()?.string(), instanceId.string())
                    XCTAssertNotNil(localState.getConnectLocation())
                    XCTAssertNotNil(localState.getDefaultLocation())
                    XCTAssertFalse(localState.getRouteLocal())
                    XCTAssertTrue(localState.getBlockerEnabled())
                }
            )
            XCTAssertTrue(didConstruct)
            XCTAssertEqual(resetCount, 0)
        }
    }

    func testClientSelectionPreservesSeparateAdminBeforeDeviceConstruction() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            let adminJwt = "separately-stored-admin-login"
            try localState.setByJwt(adminJwt)
            try seedRoutingFixture(localState, instanceId: instanceId)
            let configuredClientJwt = try clientJwt(marker: "after", issuedAt: 1_800_000_001)
            var didConstruct = false
            try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    let snapshot = try XCTUnwrap(localState.getAuthStateSnapshot())
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: {
                    XCTFail("same-instance client rotation must not clear admin or routing state")
                    try localState.logout()
                },
                selectClientJwt: {
                    try checkedTunnelSdkValue {
                        localState.selectClientJwt(forInstance: configuredClientJwt, instanceId: instanceId, error: $0)
                    }
                },
                startSession: { selectedClientJwt in
                    didConstruct = true
                    XCTAssertEqual(localState.getByJwt(), adminJwt)
                    XCTAssertEqual(selectedClientJwt, configuredClientJwt)
                    XCTAssertNotEqual(localState.getByClientJwt(), selectedClientJwt)
                    XCTAssertEqual(localState.getInstanceId()?.string(), instanceId.string())
                    XCTAssertNotNil(localState.getConnectLocation())
                    XCTAssertNotNil(localState.getDefaultLocation())
                }
            )
            XCTAssertTrue(didConstruct)
        }
    }

    func testAbsentExtensionAuthSelectionDoesNotCommitBeforeConstruction() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            let configuredClientJwt = try clientJwt(marker: "extension", issuedAt: 1_800_000_001)
            var didConstruct = false
            try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    let snapshot = try XCTUnwrap(localState.getAuthStateSnapshot())
                    XCTAssertTrue(snapshot.getEmpty())
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: {
                    XCTFail("absent auth must not authorize a destructive reset")
                    try localState.logout()
                },
                selectClientJwt: {
                    try checkedTunnelSdkValue {
                        localState.selectClientJwt(forInstance: configuredClientJwt, instanceId: instanceId, error: $0)
                    }
                },
                startSession: { selectedClientJwt in
                    didConstruct = true
                    XCTAssertTrue(localState.getByJwt().isEmpty)
                    XCTAssertEqual(selectedClientJwt, configuredClientJwt)
                    XCTAssertTrue(localState.getByClientJwt().isEmpty)
                    XCTAssertNil(localState.getInstanceId())
                }
            )
            XCTAssertTrue(didConstruct)
        }
    }


    // Local durable auth participates in startup freshness; stale profile/shared
    // tokens cannot replace it or reach the constructor.
    func testOlderConfiguredClientUsesNewerDurableClientBeforeConstruction() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            let adminJwt = "separate-admin"
            try localState.setByJwt(adminJwt)
            try seedRoutingFixture(localState, instanceId: instanceId)
            let newerClientJwt = try clientJwt(marker: "durable-newer", issuedAt: 1_800_000_010)
            try localState.setByClientJwt(newerClientJwt)
            try localState.setInstanceId(instanceId)
            let olderClientJwt = try clientJwt(marker: "profile-older", issuedAt: 1_800_000_001)
            var didConstruct = false
            try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    let snapshot = try XCTUnwrap(localState.getAuthStateSnapshot())
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(),
                        instanceId: snapshot.getInstanceId()?.string()
                    )
                },
                clearStaleState: {
                    XCTFail("credential freshness must not authorize a routing reset")
                },
                selectClientJwt: {
                    try checkedTunnelSdkValue {
                        localState.selectClientJwt(forInstance: olderClientJwt, instanceId: instanceId, error: $0)
                    }
                },
                startSession: { selectedClientJwt in
                    didConstruct = true
                    XCTAssertEqual(selectedClientJwt, newerClientJwt)
                    XCTAssertEqual(localState.getByClientJwt(), newerClientJwt)
                    XCTAssertEqual(localState.getByJwt(), adminJwt)
                    XCTAssertNotNil(localState.getConnectLocation())
                    XCTAssertNotNil(localState.getDefaultLocation())
                }
            )
            XCTAssertTrue(didConstruct)
        }
    }

    // An admin-shaped profile is invalid input, never a provider fallback.
    func testAdminOnlyConfiguredTokenCannotStartProvider() throws {
        try withLocalState { localState in
            let instanceId = try XCTUnwrap(SdkNewId())
            var didConstruct = false
            let adminOnlyJwt = try token(claims: [
                "network_id": "00000000-0000-0000-0000-000000000004",
                "user_id": "00000000-0000-0000-0000-000000000003",
            ])
            XCTAssertThrowsError(try prepareTunnelLocalAuthState(
                configuredInstanceId: instanceId.string(),
                readAuthIdentity: {
                    TunnelLocalAuthIdentitySnapshot(isEmpty: true, instanceId: nil)
                },
                clearStaleState: { XCTFail("empty auth must not be reset") },
                selectClientJwt: {
                    try checkedTunnelSdkValue {
                        localState.selectClientJwt(forInstance: adminOnlyJwt, instanceId: instanceId, error: $0)
                    }
                },
                startSession: { _ in didConstruct = true }
            ))
            XCTAssertFalse(didConstruct)
            XCTAssertTrue(localState.getByJwt().isEmpty)
            XCTAssertTrue(localState.getByClientJwt().isEmpty)
        }
    }

    // The real SDK constructor, not an API-slot read, chooses the client used
    // after startup. A relogin may subsequently install admin auth on that API.
    func testConstructedProviderPublishesSelectedClientNotInputOrAdmin() throws {
        var createdDevices: [SdkDeviceLocal] = []
        try withNetworkSpaceDirectory(devices: { createdDevices }) { networkSpace, _ in
            let localState = try XCTUnwrap(networkSpace.getAsyncLocalState()?.getLocalState())
            let instanceId = try XCTUnwrap(SdkNewId())
            let adminJwt = "separate-admin-login"
            let oldClientJwt = try clientJwt(marker: "profile-before", issuedAt: 1_800_000_000)
            let selectedClientJwt = try clientJwt(marker: "durable-after", issuedAt: 1_800_000_010)
            try localState.setByJwt(adminJwt)
            try localState.setByClientJwt(selectedClientJwt)
            try localState.setInstanceId(instanceId)
            var error: NSError?
            let created = SdkNewDeviceLocalWithMemoryTarget(
                networkSpace, oldClientJwt, "startup-test", "test", "0.0.0",
                instanceId, false, nil, 20 * 1024 * 1024, &error
            )
            // A partial returned object still owns workers. Register it before
            // interpreting NSError so fixture cleanup must join it as well.
            if let created { createdDevices.append(created) }
            if let error { throw error }
            let device = try XCTUnwrap(created)
            XCTAssertEqual(device.getClientJwt(), selectedClientJwt)
            XCTAssertEqual(localState.getByClientJwt(), selectedClientJwt)
            XCTAssertEqual(localState.getByJwt(), adminJwt)
            device.getApi()?.setByJwt(adminJwt)
            XCTAssertEqual(device.getClientJwt(), selectedClientJwt)
            XCTAssertEqual(device.getApi()?.getByJwt(), adminJwt)
        }
    }

    // The same owner is retained through RPC setup and the complete session.
    // These closures model the lifecycle calls; SDK join behavior is separate.
    func testDeviceManagerCleanupRemainsOwnedThroughStartupFailure() {
        var events: [String] = []
        func failAfterDeviceConstruction() {
            let managerCleanup = TunnelStartupCleanup { events.append("manager") }
            let sessionCleanup = TunnelStartupCleanup {
                events.append("device")
                events.append("manager")
            }
            managerCleanup.commit()
            sessionCleanup.cleanUpNow()
        }
        failAfterDeviceConstruction()
        XCTAssertEqual(events, ["device", "manager"])
    }

    func testDeviceManagerCleanupTransfersTogetherToSessionClose() {
        var events: [String] = []
        var closeSession: (() -> Void)?
        func completeDeviceConstruction() {
            let managerCleanup = TunnelStartupCleanup { events.append("manager") }
            let sessionCleanup = TunnelStartupCleanup {
                events.append("device")
                events.append("manager")
            }
            managerCleanup.commit()
            closeSession = { sessionCleanup.cleanUpNow() }
        }
        completeDeviceConstruction()
        XCTAssertEqual(events, [])
        closeSession?()
        closeSession?()
        closeSession = nil
        XCTAssertEqual(events, ["device", "manager"])
    }

    private func clientJwt(marker: String, issuedAt: Int64) throws -> String {
        try token(claims: [
            "client_id": "00000000-0000-0000-0000-000000000001",
            "device_id": "00000000-0000-0000-0000-000000000002",
            "network_id": "00000000-0000-0000-0000-000000000004",
            "iat": issuedAt,
            "exp": Int64(2_000_000_000),
            "marker": marker,
        ])
    }

    func testRealConditionalResetSupersessionCannotEraseRoutingOrKeys() throws {
        try withNetworkSpace { space in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            let instance = try XCTUnwrap(SdkNewId())
            try seedRoutingFixture(local, instanceId: instance)
            let seed = Data(repeating: 7, count: 32)
            let material = try XCTUnwrap(SdkNewDeviceLocalKeyMaterial(seed, nil, nil))
            try local.setDeviceLocalKeyMaterial(material)
            let stale = try XCTUnwrap(space.getAuthStateSnapshot())
            try local.setByClientJwt(clientJwt(marker: "renewed", issuedAt: 1_800_000_020))
            let result = try XCTUnwrap(space.resetLocalStateIfCurrent(stale))
            XCTAssertFalse(result.getReset())
            XCTAssertNotNil(try local.readConnectLocation().getLocation())
            XCTAssertNotNil(try local.readDefaultLocation().getLocation())
            XCTAssertTrue(try local.readDeviceLocalKeyMaterial().getKeyMaterial()?.getClientKeySeed() == seed,
                          "superseded reset changed retained key material")
        }
    }

    func testRealConditionalResetPreservesActualKeysButClearsOldOwnerRouting() throws {
        try withNetworkSpace { space in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            try seedRoutingFixture(local, instanceId: XCTUnwrap(SdkNewId()))
            let seed = Data(repeating: 8, count: 32)
            try local.setDeviceLocalKeyMaterial(XCTUnwrap(SdkNewDeviceLocalKeyMaterial(seed, nil, nil)))
            let observed = try XCTUnwrap(space.getAuthStateSnapshot())
            let result = try XCTUnwrap(space.resetLocalStateIfCurrent(observed))
            XCTAssertTrue(result.getReset())
            XCTAssertTrue(result.getDeviceLocalKeyMaterial()?.getClientKeySeed() == seed,
                          "reset result changed retained key material")
            XCTAssertTrue(try local.readDeviceLocalKeyMaterial().getKeyMaterial()?.getClientKeySeed() == seed,
                          "reset changed durable key material")
            XCTAssertNil(try local.readConnectLocation().getLocation())
            XCTAssertNil(try local.readDefaultLocation().getLocation())
        }
    }

    func testRealSnapshotRejectsLateDestinationWriteAfterAuthReplacement() throws {
        try withNetworkSpace { space in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            try seedRoutingFixture(local, instanceId: XCTUnwrap(SdkNewId()))
            let stale = try XCTUnwrap(space.getAuthStateSnapshot())
            let saved = try XCTUnwrap(local.readConnectLocation().getLocation())
            try local.setByClientJwt(clientJwt(marker: "new-owner", issuedAt: 1_800_000_030))
            XCTAssertThrowsError(try stale.setConnectLocation(nil))
            XCTAssertThrowsError(try stale.setDefaultLocation(nil))
            XCTAssertTrue(try XCTUnwrap(local.readConnectLocation().getLocation()).equals(saved))
            XCTAssertTrue(try XCTUnwrap(local.readDefaultLocation().getLocation()).equals(saved))
        }
    }

    func testRealCorruptDefaultDoesNotDenyValidSavedDestination() throws {
        try withNetworkSpaceDirectory { space, directory in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            try seedRoutingFixture(local, instanceId: XCTUnwrap(SdkNewId()))
            let root = try authEnvelope(in: directory).deletingLastPathComponent()
            try Data("{private-marker-invalid".utf8).write(to: root.appendingPathComponent(".default_location"))
            let snapshot = try XCTUnwrap(space.getAuthStateSnapshot())
            let plan = try restoreTunnelDestination(
                intent: .connect, savedLocationHasCurrentOwner: true,
                loadSaved: { try snapshot.readConnectLocation().getLocation() },
                loadDefault: { try snapshot.readDefaultLocation().getLocation() },
                bestAvailable: { XCTFail("saved destination must win"); return SdkConnectLocation() },
                isCurrent: { true }, apply: { XCTAssertNotNil($0.location) }
            )
            XCTAssertEqual(plan.stage, .saved)
            XCTAssertThrowsError(try local.readDefaultLocation().getLocation())
        }
    }

    func testRealMalformedSavedDestinationDoesNotBecomeFreshBestAvailable() throws {
        try withNetworkSpaceDirectory { space, directory in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            try seedRoutingFixture(local, instanceId: XCTUnwrap(SdkNewId()))
            let root = try authEnvelope(in: directory).deletingLastPathComponent()
            let malformed = Data("{private-marker-invalid".utf8)
            let path = root.appendingPathComponent(".connect_location")
            try malformed.write(to: path)
            let snapshot = try XCTUnwrap(space.getAuthStateSnapshot())
            var constructed = false
            XCTAssertThrowsError(try restoreTunnelDestination(
                intent: .connect, savedLocationHasCurrentOwner: true,
                loadSaved: { try snapshot.readConnectLocation().getLocation() },
                loadDefault: { try snapshot.readDefaultLocation().getLocation() },
                bestAvailable: { XCTFail("read failure cannot invent best available"); return SdkConnectLocation() },
                isCurrent: { true }, apply: { _ in constructed = true }
            ))
            XCTAssertFalse(constructed)
            XCTAssertEqual(try Data(contentsOf: path), malformed)
        }
    }

    func testRealExplicitDisconnectDoesNotReadUnrelatedMalformedDefault() throws {
        try withNetworkSpaceDirectory { space, directory in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            try seedRoutingFixture(local, instanceId: XCTUnwrap(SdkNewId()))
            let root = try authEnvelope(in: directory).deletingLastPathComponent()
            try Data("{malformed".utf8).write(to: root.appendingPathComponent(".default_location"))
            let snapshot = try XCTUnwrap(space.getAuthStateSnapshot())
            let plan = try restoreTunnelDestination(
                intent: .disconnect, savedLocationHasCurrentOwner: true,
                loadSaved: { try snapshot.readConnectLocation().getLocation() },
                loadDefault: { try snapshot.readDefaultLocation().getLocation() },
                bestAvailable: { XCTFail("disconnect cannot construct"); return SdkConnectLocation() },
                isCurrent: { true }, apply: { plan in
                    XCTAssertNil(plan.location)
                    try snapshot.setConnectLocation(plan.location)
                }
            )
            XCTAssertEqual(plan.stage, .explicitDisconnect)
            XCTAssertNil(try local.readConnectLocation().getLocation())
            XCTAssertThrowsError(try local.readDefaultLocation().getLocation())
        }
    }

    func testRealCheckedReadIgnoresInterruptedTemporaryDestinationRecord() throws {
        try withNetworkSpaceDirectory { space, directory in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            try seedRoutingFixture(local, instanceId: XCTUnwrap(SdkNewId()))
            let before = try XCTUnwrap(local.readConnectLocation().getLocation())
            let root = try authEnvelope(in: directory).deletingLastPathComponent()
            try Data("{partial-temporary-record".utf8).write(to: root.appendingPathComponent(".connect_location.tmp-interrupted-fixture"))
            let after = try XCTUnwrap(local.readConnectLocation().getLocation())
            XCTAssertTrue(before.equals(after))
        }
    }

    func testRealMalformedKeyReadCannotReachFreshIdentityConstruction() throws {
        try withNetworkSpaceDirectory { space, directory in
            let local = try XCTUnwrap(space.getAsyncLocalState()?.getLocalState())
            let instance = try XCTUnwrap(SdkNewId())
            try seedRoutingFixture(local, instanceId: instance)
            let root = try authEnvelope(in: directory).deletingLastPathComponent()
            let bytes = Data("{malformed-key-fixture".utf8)
            let path = root.appendingPathComponent(".device_local_key_material")
            try bytes.write(to: path)
            var constructed = false
            XCTAssertThrowsError(try prepareTunnelLocalAuthState(
                configuredInstanceId: instance.string(),
                readAuthIdentity: { TunnelLocalAuthIdentitySnapshot(isEmpty: false, instanceId: instance.string()) },
                clearStaleState: { XCTFail("same owner does not reset") },
                selectClientJwt: { local.getByClientJwt() },
                startSession: { _ in
                    _ = try local.readDeviceLocalKeyMaterial().getKeyMaterial()
                    constructed = true
                }
            ))
            XCTAssertFalse(constructed)
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testRealCheckedKeyReadPreservesOptionalSeedOnlyComponents() throws {
        try withLocalState { local in
            let seed = Data(repeating: 9, count: 32)
            try local.setDeviceLocalKeyMaterial(XCTUnwrap(SdkNewDeviceLocalKeyMaterial(seed, nil, nil)))
            let material = try XCTUnwrap(local.readDeviceLocalKeyMaterial().getKeyMaterial())
            XCTAssertTrue(material.getClientKeySeed() == seed, "checked read changed the retained seed")
            XCTAssertNil(material.getProvideTlsCertificatePem())
            XCTAssertNil(material.getProvideTlsPrivateKeyPem())
        }
    }

    func testRealCheckedKeyReadPreservesPemOnlyOptionalComponentsWithoutClaimingTlsReadiness() throws {
        try withLocalState { local in
            let certificate = Data("synthetic-certificate-fixture".utf8)
            let key = Data("synthetic-key-fixture".utf8)
            try local.setDeviceLocalKeyMaterial(XCTUnwrap(SdkNewDeviceLocalKeyMaterial(nil, certificate, key)))
            let material = try XCTUnwrap(local.readDeviceLocalKeyMaterial().getKeyMaterial())
            XCTAssertNil(material.getClientKeySeed())
            XCTAssertTrue(material.getProvideTlsCertificatePem() == certificate, "checked read changed the retained certificate")
            XCTAssertTrue(material.getProvideTlsPrivateKeyPem() == key, "checked read changed the retained private key")
        }
    }

    // Synthetic unverified JWTs exercise the SDK's selection contract only.
    private func token(claims: [String: Any]) throws -> String {
        let encode: (Data) -> String = {
            $0.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        return encode(header) + "." + encode(payload) + "."
    }

    private func seedRoutingFixture(_ localState: SdkLocalState, instanceId: SdkId) throws {
        try localState.setByClientJwt(clientJwt(marker: "before", issuedAt: 1_800_000_000))
        try localState.setInstanceId(instanceId)
        let location = SdkConnectLocation()
        let locationId = SdkConnectLocationId()
        locationId.bestAvailable = true
        location.connectLocationId = locationId
        try localState.setConnectLocation(location)
        try localState.setDefaultLocation(location)
        try localState.setRouteLocal(false)
        try localState.setBlockerEnabled(true)
    }

    // The fresh manager has no active token and only loopback test endpoints;
    // these tests exercise storage without a NetworkExtension or remote service.
    private func withLocalState(_ body: (SdkLocalState) throws -> Void) throws {
        try withNetworkSpace { networkSpace in
            let localState = try XCTUnwrap(networkSpace.getAsyncLocalState()?.getLocalState())
            try body(localState)
        }
    }

    private func withNetworkSpace(_ body: (SdkNetworkSpace) throws -> Void) throws {
        try withNetworkSpaceDirectory { networkSpace, _ in
            try body(networkSpace)
        }
    }

    // Locate only this fixture's real SDK envelope, without depending on the
    // manager's host/environment directory encoding.
    private func authEnvelope(in directory: URL) throws -> URL {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ))
        let matches = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == ".auth_state" }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.first)
    }

    private func withNetworkSpaceDirectory(
        devices: () -> [SdkDeviceLocal] = { [] },
        _ body: (SdkNetworkSpace, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tunnel-auth-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var createdManager: SdkNetworkSpaceManager?
        defer {
            let ownedDevices = devices()
            ownedDevices.forEach { $0.close() }
            var allJoined = true
            for device in ownedDevices {
                if !device.wait(forClose: 5_000) {
                    allJoined = false
                    XCTFail("auth storage fixture SDK owner failed bounded join; store retained")
                }
            }
            if allJoined {
                createdManager?.close()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let manager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
        createdManager = manager
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try XCTUnwrap(SdkNewNetworkSpaceKey("startup.test", "test"))
        let networkSpace = try XCTUnwrap(manager.updateNetworkSpaceValues(key, values: values))
        try body(networkSpace, directory)
    }
}
