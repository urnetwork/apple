//
//  SessionsSdkTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The SDK side of Account > Sessions: the store's copy of the controller's
 * typed snapshot (the session list, the nullable last use in Unix seconds,
 * the creation time in milliseconds, actions and error flags), and the
 * controller the account api opens (Api.OpenClientSessionViewController).
 * Nothing is started, so no request or goroutine runs.
 */
@MainActor
struct SessionsSdkTests {

    // test-only session ids
    private static let thisSession = "01a1f3c2-0000-4000-8000-00000000000a"
    private static let otherSession = "02b2e4d3-0000-4000-8000-00000000000b"

    private static func id(_ value: String) throws -> SdkId {
        try #require(SdkParseId(value, nil))
    }

    @Test func theSnapshotIsCopiedFieldByField() throws {
        let current = SdkNetworkSessionInfo()
        current.sessionId = try Self.id(Self.thisSession)
        current.current = true
        current.kind = "google"
        current.createTime = SdkTime(unixMilli: 1_790_400_000_000)
        let lastUsed = SdkSessionLastUsed()
        lastUsed.unixTime = 1_790_999_700
        lastUsed.city = "Chicago"
        lastUsed.region = "Illinois"
        lastUsed.country = "United States"
        lastUsed.countryCode = "us"
        lastUsed.deviceType = "ios"
        lastUsed.appVersion = "2026.10.8-1066894190"
        current.lastUsed = lastUsed

        // a legacy session with no observed use and no creation time
        let other = SdkNetworkSessionInfo()
        other.sessionId = try Self.id(Self.otherSession)
        other.kind = "legacy"

        // a row without an id is not listed
        let noId = SdkNetworkSessionInfo()
        noId.kind = "password"

        let sessions = try #require(SdkNewNetworkSessionInfoList())
        sessions.add(current)
        sessions.add(other)
        sessions.add(noId)

        let actionError = SdkClientSessionError()
        actionError.retryable = true
        let action = SdkClientSessionAction()
        action.sessionId = try Self.id(Self.otherSession)
        action.pending = true
        action.error = actionError
        let actions = try #require(SdkNewClientSessionActionList())
        actions.add(action)
        let bulkAction = SdkClientSessionAction()
        bulkAction.loading = true
        let error = SdkClientSessionError()
        error.signInRequired = true
        error.message = "a raw message the screen never shows"

        let snapshot = SdkClientSessionSnapshot()
        snapshot.sessions = sessions
        snapshot.currentSessionId = try Self.id(Self.thisSession)
        snapshot.legacyCoverage = "partial"
        snapshot.loaded = true
        snapshot.refreshing = true
        snapshot.supported = true
        snapshot.actions = actions
        snapshot.bulkAction = bulkAction
        snapshot.error = error

        #expect(SessionsSnapshot(snapshot) == SessionsSnapshot(
            sessions: [
                SessionItem(
                    id: Self.thisSession,
                    current: true,
                    kind: "google",
                    createTimeMillis: 1_790_400_000_000,
                    lastUsed: SessionLastUsedItem(
                        unixTime: 1_790_999_700,
                        city: "Chicago",
                        region: "Illinois",
                        country: "United States",
                        countryCode: "us",
                        deviceType: "ios",
                        appVersion: "2026.10.8-1066894190"
                    )
                ),
                SessionItem(id: Self.otherSession, current: false, kind: "legacy", createTimeMillis: nil, lastUsed: nil),
            ],
            currentSessionId: Self.thisSession,
            legacyCoverage: "partial",
            loaded: true,
            loading: false,
            refreshing: true,
            supported: true,
            bulkAction: SessionActionItem(sessionId: nil, loading: true, pending: false, error: nil),
            actions: [
                SessionActionItem(sessionId: Self.otherSession, loading: false, pending: true, error: SessionErrorItem(retryable: true)),
            ],
            error: SessionErrorItem(retryable: false, signInRequired: true, unsupported: false)
        ))
    }

    @Test func noSnapshotIsTheEmptyOne() {
        #expect(SessionsSnapshot(nil) == SessionsSnapshot())
    }

    // the api-only entry point, opened and closed on a real network space's
    // api; before Start it reads the controller's empty snapshot
    @Test func theAccountApiOpensTheController() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sessions-controller-test-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let spaceManager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            spaceManager.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let values = SdkNetworkSpaceValues()
        values.apiUrl = "http://127.0.0.1:1"
        values.platformUrl = "ws://127.0.0.1:1"
        let key = try #require(SdkNewNetworkSpaceKey("sessions-controller.example", "test"))
        let space = try #require(spaceManager.updateNetworkSpaceValues(key, values: values))
        let api = try #require(space.getApi())

        let controller = try #require(api.openClientSessionController())
        #expect(controller.readSnapshot() == SessionsSnapshot(legacyCoverage: "partial", supported: true))
        let listenerSub = controller.addSnapshotListener {}
        #expect(listenerSub != nil)
        listenerSub?.close()
        controller.close()
        // closed: still readable, and a second close is harmless
        #expect(controller.readSnapshot().sessions.isEmpty)
        controller.close()
    }
}
