//
//  SlowInternetWidgetPillTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/**
 * The dashboard widget's slow internet pill (apple/DELAY.md §5.7): it shows
 * the notice's content, so it follows the notice's dwell rather than the
 * reading, and only while the widget shows tunnel data and the extension's
 * snapshot is fresh and from a running tunnel. It has no recovered state, and
 * it says what the in-app pill says for the same numbers. The extension
 * reloads the widget when the pill appears or leaves or its level or label
 * changes, never for a refresh of the numbers.
 */
struct SlowInternetWidgetPillTests {

    typealias Pill = SlowInternetWidgetPill
    typealias ContentState = TransportDelayAttributes.ContentState

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Level 3, the download the worse direction.
    private static let slow = TransportDelayReading(
        upQuality: 0.5,
        downQuality: 0.75,
        upBitsPerSecond: 48_000,
        downBitsPerSecond: 85_000,
        upDelayMillis: 800,
        downDelayMillis: 1900
    )

    /// The notice showing `reading`.
    private static func notice(_ reading: TransportDelayReading = slow) -> ContentState {
        ContentState(reading: reading, previousLevel: 0)
    }

    /// The extension's snapshot, written `age` seconds ago.
    private func snapshot(
        _ activity: ContentState? = SlowInternetWidgetPillTests.notice(),
        age: TimeInterval = 10,
        tunnelActive: Bool = true
    ) -> TransportDelaySnapshot {
        TransportDelaySnapshot(
            updatedAt: now.addingTimeInterval(-age),
            tunnelActive: tunnelActive,
            reading: Self.slow,
            activity: activity,
            staleDate: activity == nil ? nil : now.addingTimeInterval(60 - age)
        )
    }

    private func decide(_ snapshot: TransportDelaySnapshot?, showsTunnelData: Bool = true) -> Pill? {
        Pill.decide(snapshot: snapshot, showsTunnelData: showsTunnelData, now: now)
    }

    // MARK: when it shows

    // while the notice shows: its level, and what the in-app pill says for
    // its numbers
    @Test func itShowsTheNoticesLevelAndNumbers() throws {
        let pill = try #require(decide(snapshot()))
        #expect(pill.level == 3)
        #expect(pill.content == SlowInternetPillContent(reading: Self.slow))
        #expect(pill.content.label == .poorSignal)
        #expect(pill.content.up == "800 ms")
        #expect(pill.content.down == "1.9 s")
        #expect(pill.content.worse == .down)
        #expect(!pill.content.recovered)
    }

    // the notice's dwell, not the reading: a slow reading the dwell has not
    // shown yet shows nothing, and a notice waiting out its minimum on a
    // normal reading still shows its last level
    @Test func itFollowsTheNoticeNotTheReading() throws {
        #expect(decide(snapshot(nil)) == nil)

        var waiting = snapshot(Self.notice().settled)
        waiting.reading = .normal
        #expect(try #require(decide(waiting)).level == 3)
    }

    // no recovered state: a widget cannot hold one for 3 s
    @Test func theRecoveredStateShowsNothing() {
        #expect(decide(snapshot(Self.notice().recoveredState)) == nil)
    }

    // nothing with no snapshot (the Mac's extension writes none), from a
    // stopped tunnel, from an extension that stopped writing, or while the
    // widget shows no tunnel data (signed out or disconnected)
    @Test func itShowsOnlyAFreshLiveSnapshotWithTunnelData() {
        #expect(decide(nil) == nil)
        #expect(decide(snapshot(tunnelActive: false)) == nil)
        #expect(decide(snapshot(age: 89)) != nil)
        #expect(decide(snapshot(age: 90)) == nil)
        #expect(decide(snapshot(age: 3600)) == nil)
        #expect(decide(snapshot(), showsTunnelData: false) == nil)
    }

    // MARK: what it says

    // the in-app pill's rules on the notice's numbers: "Fallback" on the
    // fallback connection, each direction's delay, else its limited rate,
    // else nothing
    @Test func itSaysWhatTheInAppPillSays() throws {
        var fallback = Self.slow
        fallback.fallback = true
        let readings = [
            Self.slow,
            fallback,
            // no delay either way, both limited
            TransportDelayReading(downQuality: 0.75, upBitsPerSecond: 150_000, downBitsPerSecond: 280_000),
            TransportDelayReading(downQuality: 0.25, downDelayMillis: 640),
            TransportDelayReading(upQuality: 0.5),
        ]
        for reading in readings {
            let pill = try #require(decide(snapshot(Self.notice(reading))))
            #expect(pill.content == SlowInternetPillContent(reading: reading))
            #expect(pill.level == reading.level)
        }
        #expect(try #require(decide(snapshot(Self.notice(fallback)))).content.label == .fallback)
    }

    // MARK: reloads

    private func changed(_ previous: TransportDelaySnapshot?, _ next: TransportDelaySnapshot) -> Bool {
        TransportDelaySnapshot.dashboardChanged(from: previous, to: next)
    }

    // the dashboard reloads when the pill appears or leaves, or its level or
    // its label changes; never for the numbers
    @Test func theDashboardReloadsForWhatThePillDraws() {
        let hidden = snapshot(nil)
        let shown = snapshot()
        #expect(!changed(nil, hidden))
        #expect(!changed(hidden, hidden))
        #expect(changed(hidden, shown))
        #expect(changed(nil, shown))

        // a refresh of the numbers, written later
        var numbers = Self.slow
        numbers.upDelayMillis = 950
        numbers.downBitsPerSecond = 120_000
        #expect(!changed(shown, snapshot(Self.notice(numbers), age: 0)))

        var deeper = Self.slow
        deeper.downQuality = 1
        #expect(changed(shown, snapshot(Self.notice(deeper))))
        var fallback = Self.slow
        fallback.fallback = true
        #expect(changed(shown, snapshot(Self.notice(fallback))))

        // it leaves for the recovered state, the tunnel stopping or the
        // notice ending; the end after the recovered state draws nothing new
        let recovered = snapshot(Self.notice().recoveredState)
        #expect(changed(shown, recovered))
        #expect(changed(shown, snapshot(tunnelActive: false)))
        #expect(changed(shown, hidden))
        #expect(!changed(recovered, hidden))
    }

    // the scripted episode, stepped the way the extension steps it: a reload
    // when the pill appears, at each change of level and when it leaves for
    // the recovered state; none for the refresh of the numbers or the end
    @Test func theEpisodeReloadsOnlyForWhatThePillDraws() {
        var policy = TransportDelayActivityPolicy()
        _ = policy.step(.enabled(true), now: now)
        var last: TransportDelaySnapshot?
        var reloads: [String] = []
        var elapsed: TimeInterval = 0
        while elapsed <= 2 * TransportDelaySimulation.duration {
            let at = now.addingTimeInterval(elapsed)
            let reading = TransportDelaySimulation.reading(elapsed: elapsed) ?? .normal
            _ = policy.step(.reading(reading), now: at)
            let written = TransportDelaySnapshot(
                updatedAt: at,
                tunnelActive: true,
                reading: policy.reading,
                activity: policy.content,
                staleDate: nil
            )
            if TransportDelaySnapshot.dashboardChanged(from: last, to: written) {
                let pill = Pill.decide(snapshot: written, showsTunnelData: true, now: at)
                reloads.append("\(Int(elapsed)) \(pill.map { "level \($0.level)" } ?? "hidden")")
            }
            last = written
            let change = TransportDelaySimulation.nextChange(after: elapsed)
            let deadline = policy.nextDeadline(now: at).map { $0.timeIntervalSince(now) }
            guard let next = [change, deadline].compactMap({ $0 }).min() else {
                break
            }
            elapsed = next
        }
        #expect(reloads == [
            "30 level 2",
            "40 level 4",
            "55 level 3",
            "90 hidden",
        ])
    }
}
