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
 * the creation time in milliseconds, the client groups and the counts,
 * actions and error flags), and the controller the account api opens
 * (Api.OpenClientSessionViewController). Nothing is started, so no request or
 * goroutine runs.
 */
@MainActor
struct SessionsSdkTests {

    // test-only session ids
    private static let thisSession = "01a1f3c2-0000-4000-8000-00000000000a"
    private static let otherSession = "02b2e4d3-0000-4000-8000-00000000000b"
    private static let proxySession = "04d4e6f5-0000-4000-8000-00000000000d"

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

        // an open group of hosted proxies with more rows, and a collapsed
        // group of API clients, which carries no rows
        let proxy = SdkNetworkSessionInfo()
        proxy.sessionId = try Self.id(Self.proxySession)
        proxy.kind = "legacy_proxy"
        let proxyRows = try #require(SdkNewNetworkSessionInfoList())
        proxyRows.add(proxy)
        let proxies = SdkClientSessionGroup()
        proxies.kind = SdkClientSessionGroupHostedProxies
        proxies.count = 1_234
        proxies.expanded = true
        proxies.sessions = proxyRows
        proxies.hasMore = true
        let apiClients = SdkClientSessionGroup()
        apiClients.kind = SdkClientSessionGroupApiClients
        apiClients.count = 3
        let groups = try #require(SdkNewClientSessionGroupList())
        groups.add(proxies)
        groups.add(apiClients)

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
        error.sessionRevoked = true
        error.message = "a raw message the screen never shows"

        let snapshot = SdkClientSessionSnapshot()
        snapshot.sessions = sessions
        snapshot.sessionCount = 51
        snapshot.sessionsHasMore = true
        snapshot.groups = groups
        snapshot.otherSessionCount = 53
        snapshot.truncated = true
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
            sessionCount: 51,
            sessionsHasMore: true,
            groups: [
                SessionGroupItem(
                    kind: SdkClientSessionGroupHostedProxies,
                    count: 1_234,
                    expanded: true,
                    sessions: [SessionItem(id: Self.proxySession, current: false, kind: "legacy_proxy", createTimeMillis: nil, lastUsed: nil)],
                    hasMore: true
                ),
                SessionGroupItem(kind: SdkClientSessionGroupApiClients, count: 3, expanded: false, sessions: [], hasMore: false),
            ],
            otherSessionCount: 53,
            truncated: true,
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
            error: SessionErrorItem(retryable: false, signInRequired: true, sessionRevoked: true, unsupported: false)
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
        // a group opened and Show more are presentation only: without a list
        // nothing shows, and nothing is requested
        controller.setGroupExpanded(kind: SdkClientSessionGroupHostedProxies, expanded: true)
        controller.showMoreSessions(kind: SdkClientSessionGroupSignIns)
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
