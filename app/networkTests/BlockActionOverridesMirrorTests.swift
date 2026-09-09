//
//  BlockActionOverridesMirrorTests.swift
//  networkTests
//
//  Covers the store the split rules are mirrored into.
//
//  The rules themselves live in the network extension's container, which the
//  app process cannot read, so this mirror is the app's only durable copy --
//  it is what the sheet renders from with the tunnel down and what
//  DeviceManager.initDevice seeds the next device from.
//
//  Two of these cases are the ones the fix would be silently wrong without.
//  Writing nil DELETES the store, and a deleted store reads back exactly like
//  one that was never written, so "the user removed their last rule" and "this
//  install has never mirrored" are the same value unless an empty list is
//  written as an empty list. The first would resurrect deleted rules on the
//  next connect; the second would push an empty list over rules the extension
//  still holds. Everything BlockActionsStore.persistOverrides and the seed's
//  `if let` do rests on that distinction.
//

import Testing
import Foundation
import URnetworkSdk
@testable import URnetwork

struct BlockActionOverridesMirrorTests {

    /// Each test gets its own storage home; the SDK roots the store at
    /// `<home>/.by`, so a fresh temporary directory is a fresh store.
    private func withLocalState(_ body: (SdkLocalState) throws -> Void) rethrows {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlockActionOverridesMirrorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        guard let asyncLocalState = SdkAsyncLocalState(home.path()),
              let localState = asyncLocalState.getLocalState() else {
            Issue.record("could not open a local state under \(home.path())")
            return
        }
        defer { asyncLocalState.close() }
        try body(localState)
    }

    private func override(
        hosts: [String],
        local: Bool = false,
        pin: Bool = false
    ) -> SdkBlockActionOverride {
        let override = SdkBlockActionOverride()
        override.overrideId = SdkNewId()
        let hostList = SdkStringList()
        for host in hosts {
            hostList?.add(host)
        }
        override.hosts = hostList
        let routeOverride = SdkRouteOverride()
        routeOverride.local = local
        routeOverride.pin = pin
        override.routeOverride = routeOverride
        return override
    }

    private func list(_ overrides: [SdkBlockActionOverride]) -> SdkBlockActionOverrideList {
        let list = SdkBlockActionOverrideList()
        for override in overrides {
            list?.add(override)
        }
        return list!
    }

    private func hosts(_ override: SdkBlockActionOverride) -> [String] {
        guard let hosts = override.hosts else {
            return []
        }
        return (0..<hosts.len()).map { hosts.get($0) }
    }

    /// The fields SplitRuleMode.of reads to decide a rule's chip -- an
    /// override that round-trips without them renders as the wrong mode.
    @Test func rulesRoundTripWithTheirIdHostsAndMode() throws {
        try withLocalState { localState in
            let excluded = override(hosts: ["*.example.com", "10.0.0.0/8"], local: true)
            let pinned = override(hosts: ["api.example.org"], pin: true)
            let excludedId = excluded.overrideId?.idStr
            let pinnedId = pinned.overrideId?.idStr

            try localState.setBlockActionOverrides(list([excluded, pinned]))

            let read = try #require(localState.getBlockActionOverrides())
            #expect(read.len() == 2)

            let first = try #require(read.get(0))
            #expect(first.overrideId?.idStr == excludedId)
            #expect(hosts(first) == ["*.example.com", "10.0.0.0/8"])
            #expect(first.routeOverride?.local == true)
            #expect(first.routeOverride?.pin == false)

            let second = try #require(read.get(1))
            #expect(second.overrideId?.idStr == pinnedId)
            #expect(hosts(second) == ["api.example.org"])
            #expect(second.routeOverride?.local == false)
            #expect(second.routeOverride?.pin == true)
        }
    }

    /// The mirror copies the device's own override objects rather than the
    /// SplitRuleItem projection the UI renders, so fields the app never models
    /// have to survive it too.
    @Test func fieldsTheAppDoesNotModelSurviveTheRoundTrip() throws {
        try withLocalState { localState in
            let unrouted = SdkBlockActionOverride()
            unrouted.overrideId = SdkNewId()
            let blocked = override(hosts: ["ads.example.com"])
            let blockOverride = SdkBlockOverride()
            blockOverride.block = true
            blocked.blockOverride = blockOverride

            try localState.setBlockActionOverrides(list([unrouted, blocked]))

            let read = try #require(localState.getBlockActionOverrides())
            #expect(read.len() == 2)
            #expect(try #require(read.get(0)).routeOverride == nil)
            #expect(try #require(read.get(1)).blockOverride?.block == true)
        }
    }

    /// "I deleted my last rule" -- an empty list is a real value and has to
    /// come back as one, or the seed skips it and the extension's copy stands.
    @Test func anEmptyListRoundTripsAsAnEmptyList() throws {
        try withLocalState { localState in
            try localState.setBlockActionOverrides(list([override(hosts: ["example.com"])]))
            try localState.setBlockActionOverrides(list([]))

            let read = localState.getBlockActionOverrides()
            #expect(read != nil)
            #expect(read?.len() == 0)
        }
    }

    /// Writing nil is the delete branch. persistOverrides must never reach it:
    /// the result is indistinguishable from an install that never mirrored.
    @Test func writingNilDeletesTheStore() throws {
        try withLocalState { localState in
            try localState.setBlockActionOverrides(list([override(hosts: ["example.com"])]))
            #expect(localState.getBlockActionOverrides() != nil)

            try localState.setBlockActionOverrides(nil)

            #expect(localState.getBlockActionOverrides() == nil)
        }
    }

    /// The upgrade guard. A build that has never mirrored reads nil, so
    /// DeviceManager.initDevice queues nothing and the rules a pre-fix build
    /// left in the extension are still there on the first launch after this
    /// ships -- rather than being replaced by an empty list.
    @Test func aStoreThatWasNeverWrittenReadsNilRatherThanEmpty() throws {
        try withLocalState { localState in
            #expect(localState.getBlockActionOverrides() == nil)
        }
    }
}
