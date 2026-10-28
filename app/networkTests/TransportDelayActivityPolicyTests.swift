//
//  TransportDelayActivityPolicyTests.swift
//  networkTests
//

import Foundation
import Testing
@testable import URnetwork

/**
 * The slow internet Live Activity's dwell (apple/DELAY.md §5.5): it appears
 * only once the level has been above 0 for 30 s of the last 60 s, stays at
 * least 60 s, shows the recovered state 3 s before it ends, updates at once
 * on a level change and refreshes its numbers at most every 30 s. The policy
 * is a pure value, so each test steps it through time by hand.
 */
struct TransportDelayActivityPolicyTests {

    typealias Policy = TransportDelayActivityPolicy
    typealias ContentState = TransportDelayAttributes.ContentState

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    private static func slow(_ level: Int, up: Int64 = 640, down: Int64 = 1200, fallback: Bool = false) -> TransportDelayReading {
        TransportDelayReading(
            upQuality: TransportDelayLevel.quality(level: level),
            downQuality: 0,
            upBitsPerSecond: 48_000,
            downBitsPerSecond: 0,
            upDelayMillis: up,
            downDelayMillis: down,
            fallback: fallback
        )
    }

    /// A policy enabled at 0, slow from 0, shown at 30.
    private func shownPolicy(level: Int = 2) -> Policy {
        var policy = Policy()
        _ = policy.step(.enabled(true), now: at(0))
        _ = policy.step(.reading(Self.slow(level)), now: at(0))
        let action = policy.step(.tick, now: at(30))
        #expect(action == .start(ContentState(reading: Self.slow(level), previousLevel: 0)))
        return policy
    }

    // MARK: appearing

    @Test func itAppearsOnlyAfterThirtySecondsOfSlowTime() {
        var policy = Policy()
        #expect(policy.step(.enabled(true), now: at(0)) == nil)
        #expect(policy.step(.reading(Self.slow(2)), now: at(0)) == nil)
        #expect(policy.step(.tick, now: at(29)) == nil)
        #expect(policy.nextDeadline(now: at(29)) == at(30))
        let action = policy.step(.tick, now: at(30))
        #expect(action == .start(ContentState(reading: Self.slow(2), previousLevel: 0)))
        #expect(policy.phase == .shown(since: at(30)))
    }

    // the deadline asks to be stepped when the dwell can complete, no sooner
    @Test func theDeadlineIsWhenTheDwellCanComplete() {
        var policy = Policy()
        _ = policy.step(.enabled(true), now: at(0))
        // normal: nothing is due
        #expect(policy.nextDeadline(now: at(0)) == nil)
        _ = policy.step(.reading(Self.slow(1)), now: at(0))
        #expect(policy.nextDeadline(now: at(0)) == at(30))
        #expect(policy.nextDeadline(now: at(10)) == at(30))
    }

    // short spells that never add up to 30 s in a minute never show
    @Test func aFlappingLevelDoesNotAppear() {
        var policy = Policy()
        _ = policy.step(.enabled(true), now: at(0))
        var actions: [Policy.Action] = []
        // slow 10 s, normal 20 s, for five minutes
        var t: TimeInterval = 0
        while t < 300 {
            if let action = policy.step(.reading(Self.slow(3)), now: at(t)) { actions.append(action) }
            if let action = policy.step(.tick, now: at(t + 9)) { actions.append(action) }
            if let action = policy.step(.reading(.normal), now: at(t + 10)) { actions.append(action) }
            if let action = policy.step(.tick, now: at(t + 29)) { actions.append(action) }
            t += 30
        }
        #expect(actions.isEmpty)
        #expect(policy.phase == .hidden)
    }

    // slow time within the window adds up across short normal gaps
    @Test func slowTimeAddsUpWithinTheWindow() {
        var policy = Policy()
        _ = policy.step(.enabled(true), now: at(0))
        #expect(policy.step(.reading(Self.slow(1)), now: at(0)) == nil)
        #expect(policy.step(.reading(.normal), now: at(20)) == nil)
        #expect(policy.step(.reading(Self.slow(1)), now: at(30)) == nil)
        #expect(policy.slowDuration(now: at(35)) == 25)
        #expect(policy.step(.tick, now: at(39)) == nil)
        #expect(policy.step(.tick, now: at(40)) == .start(ContentState(reading: Self.slow(1), previousLevel: 0)))
    }

    // the tunnel down shows nothing, whatever the notify toggle says (it
    // gates only the notification); connected while slow, the slow time
    // already counted shows it at once
    @Test func itStartsOnlyWhileEnabled() {
        var policy = Policy()
        _ = policy.step(.reading(Self.slow(4)), now: at(0))
        #expect(policy.step(.tick, now: at(45)) == nil)
        #expect(policy.nextDeadline(now: at(45)) == nil)
        #expect(policy.step(.enabled(true), now: at(45)) == .start(ContentState(reading: Self.slow(4), previousLevel: 0)))
    }

    // MARK: while up

    // a level change updates at once, ordered from the level before it; the
    // numbers alone wait for the 30 s refresh
    @Test func aLevelChangeUpdatesAtOnceAndNumbersAtMostEveryThirtySeconds() {
        var policy = shownPolicy(level: 2)
        let deeper = policy.step(.reading(Self.slow(3)), now: at(35))
        #expect(deeper == .update(ContentState(reading: Self.slow(3), previousLevel: 2)))
        // the same level with new numbers: nothing until the refresh
        let moved = Self.slow(3, up: 900, down: 1800)
        #expect(policy.step(.reading(moved), now: at(40)) == nil)
        #expect(policy.nextDeadline(now: at(40)) == at(65))
        #expect(policy.step(.tick, now: at(64)) == nil)
        let refresh = policy.step(.tick, now: at(65))
        #expect(refresh == .update(ContentState(reading: moved, previousLevel: 3)))
        // a refresh moves only the numbers: the tunnel keeps its level
        if case .update(let content)? = refresh {
            #expect(content.level == content.previousLevel)
        }
    }

    // the copy switches with the fallback at once, the level unchanged
    @Test func theFallbackSwitchesAtOnce() {
        var policy = shownPolicy(level: 2)
        let action = policy.step(.reading(Self.slow(2, fallback: true)), now: at(31))
        #expect(action == .update(ContentState(reading: Self.slow(2, fallback: true), previousLevel: 2)))
    }

    // back to normal it stays its minimum 60 s, showing the last slow content
    // (refreshed so it does not go stale), then shows the recovered state
    @Test func itStaysAtLeastSixtySeconds() {
        var policy = shownPolicy(level: 2)
        #expect(policy.step(.reading(.normal), now: at(40)) == nil)
        #expect(policy.nextDeadline(now: at(40)) == at(60))
        let refresh = policy.step(.tick, now: at(60))
        #expect(refresh == .update(ContentState(reading: Self.slow(2), previousLevel: 2)))
        #expect(policy.nextDeadline(now: at(60)) == at(90))
        #expect(policy.step(.tick, now: at(89)) == nil)
        let recovered = policy.step(.tick, now: at(90))
        #expect(recovered == .update(ContentState(reading: Self.slow(2), previousLevel: 0).recoveredState))
        #expect(policy.phase == .recovered(since: at(90)))
        if case .update(let content)? = recovered {
            #expect(content.recovered)
            #expect(content.level == 0)
            #expect(content.previousLevel == 2)
        }
    }

    // after its minimum, a return to normal shows the recovered state at once
    @Test func afterItsMinimumNormalRecoversAtOnce() {
        var policy = shownPolicy(level: 1)
        _ = policy.step(.tick, now: at(60))
        let recovered = policy.step(.reading(.normal), now: at(95))
        #expect(recovered == .update(ContentState(reading: Self.slow(1), previousLevel: 0).recoveredState))
    }

    // the recovered state shows 3 s, then the activity ends at once
    @Test func theRecoveredStateEndsAfterThreeSeconds() {
        var policy = shownPolicy(level: 2)
        _ = policy.step(.reading(.normal), now: at(91))
        #expect(policy.phase == .recovered(since: at(91)))
        #expect(policy.nextDeadline(now: at(91)) == at(94))
        #expect(policy.step(.tick, now: at(93.9)) == nil)
        #expect(policy.step(.tick, now: at(94)) == .end)
        #expect(policy.phase == .hidden)
        #expect(policy.content == nil)
    }

    // slow again before the end: the same activity carries on, and stays its
    // minimum again
    @Test func slowAgainDuringTheRecoveredStateCarriesOn() {
        var policy = shownPolicy(level: 2)
        _ = policy.step(.reading(.normal), now: at(91))
        let again = policy.step(.reading(Self.slow(3)), now: at(92))
        #expect(again == .update(ContentState(reading: Self.slow(3), previousLevel: 0)))
        #expect(policy.phase == .shown(since: at(92)))
        #expect(policy.step(.reading(.normal), now: at(100)) == nil)
        #expect(policy.nextDeadline(now: at(100)) == at(122))
    }

    // after an end, the next activity dwells on new slow time
    @Test func afterAnEndANewActivityNeedsNewSlowTime() {
        var policy = shownPolicy(level: 2)
        _ = policy.step(.reading(.normal), now: at(91))
        #expect(policy.step(.tick, now: at(94)) == .end)
        #expect(policy.step(.reading(Self.slow(2)), now: at(95)) == nil)
        #expect(policy.step(.tick, now: at(124)) == nil)
        #expect(policy.step(.tick, now: at(125)) == .start(ContentState(reading: Self.slow(2), previousLevel: 0)))
    }

    // MARK: ending

    // the tunnel stopping or a sign out end it at once
    @Test func disablingEndsAtOnce() {
        var policy = shownPolicy(level: 4)
        #expect(policy.step(.enabled(false), now: at(31)) == .end)
        #expect(policy.phase == .hidden)
        #expect(policy.step(.tick, now: at(200)) == nil)
    }

    // a user's dismissal holds for the rest of the slow spell; a new spell,
    // after a whole window without slow time, shows again
    @Test func aDismissalHoldsUntilTheSpellIsOver() {
        var policy = shownPolicy(level: 2)
        #expect(policy.step(.gone(dismissedByUser: true), now: at(40)) == nil)
        #expect(policy.suppressed)
        #expect(policy.step(.tick, now: at(200)) == nil)
        #expect(policy.nextDeadline(now: at(200)) == nil)
        // a short normal gap is the same spell
        _ = policy.step(.reading(.normal), now: at(300))
        #expect(policy.step(.reading(Self.slow(2)), now: at(330)) == nil)
        #expect(policy.step(.tick, now: at(400)) == nil)
        // a whole minute normal, then a new spell dwells and shows
        _ = policy.step(.reading(.normal), now: at(400))
        _ = policy.step(.reading(Self.slow(2)), now: at(470))
        #expect(!policy.suppressed)
        #expect(policy.step(.tick, now: at(500)) == .start(ContentState(reading: Self.slow(2), previousLevel: 0)))
    }

    // connecting again lifts a dismissal
    @Test func connectingAgainLiftsADismissal() {
        var policy = shownPolicy(level: 2)
        _ = policy.step(.gone(dismissedByUser: true), now: at(40))
        _ = policy.step(.enabled(false), now: at(41))
        #expect(policy.step(.enabled(true), now: at(42)) == .start(ContentState(reading: Self.slow(2), previousLevel: 0)))
    }

    // the system ends an activity at eight hours: a new one starts at once
    // if the connection is still slow
    @Test func theSystemsEndAtItsLimitStartsANewOne() {
        var policy = shownPolicy(level: 3)
        let later = 30 + Policy.maximumDuration
        _ = policy.step(.tick, now: at(later - 1))
        #expect(policy.shownDuration(now: at(later)) == Policy.maximumDuration)
        #expect(policy.step(.gone(dismissedByUser: false), now: at(later)) == .start(ContentState(reading: Self.slow(3), previousLevel: 0)))
        #expect(policy.phase == .shown(since: at(later)))
    }

    @Test func eachUpdateIsStaleAMinuteLater() {
        #expect(Policy.staleDate(now: at(10)) == at(70))
    }
}

/**
 * The slow internet notification over the policy's episodes (apple/DELAY.md
 * §3, §5.5). "Notify me when my internet is slow" gates only the
 * notification: the dwell, and the dashboard widget's pill with it, run
 * whatever it says. An episode's notification moment is its start, spent
 * whether or not the toggle posts it, so the toggle turned on mid-episode
 * posts nothing until the next; turned off, it withdraws what is posted.
 */
struct TransportDelayNoticeTests {

    typealias Notice = TransportDelayNotice
    typealias ContentState = TransportDelayAttributes.ContentState

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func slow(_ level: Int, fallback: Bool = false) -> TransportDelayReading {
        TransportDelayReading(upQuality: TransportDelayLevel.quality(level: level), upDelayMillis: 640, fallback: fallback)
    }

    private static func content(_ level: Int, fallback: Bool = false) -> ContentState {
        ContentState(reading: slow(level, fallback: fallback), previousLevel: 0)
    }

    // posted at the start, then again only when what it says changes: the
    // fallback, the recovered state, slow again during it. A change of level
    // posts nothing, and the end withdraws it
    @Test func itPostsOnlyWhenWhatItSaysChanges() {
        var notice = Notice()
        #expect(notice.step(.start(Self.content(2)), enabled: true) == .post(.slow(fallback: false)))
        #expect(notice.step(.update(Self.content(3)), enabled: true) == nil)
        #expect(notice.step(.update(Self.content(3, fallback: true)), enabled: true) == .post(.slow(fallback: true)))
        #expect(notice.step(.update(Self.content(3).recoveredState), enabled: true) == .post(.recovered))
        #expect(notice.step(.update(Self.content(1)), enabled: true) == .post(.slow(fallback: false)))
        #expect(notice.setting(enabled: true) == nil)
        #expect(notice.step(.end, enabled: true) == .withdraw)
        #expect(notice.posted == nil)
    }

    // the toggle off spends the episode's moment unposted: turned on
    // mid-episode, it posts nothing until the next episode starts
    @Test func theToggleTurnedOnMidEpisodePostsNothingUntilTheNext() {
        var notice = Notice()
        #expect(notice.step(.start(Self.content(2)), enabled: false) == nil)
        #expect(notice.setting(enabled: true) == nil)
        #expect(notice.step(.update(Self.content(4)), enabled: true) == nil)
        #expect(notice.step(.update(Self.content(4, fallback: true)), enabled: true) == nil)
        #expect(notice.step(.update(Self.content(4).recoveredState), enabled: true) == nil)
        #expect(notice.step(.end, enabled: true) == nil)
        #expect(notice.step(.start(Self.content(1)), enabled: true) == .post(.slow(fallback: false)))
    }

    // turned off, the toggle withdraws the notification at once, and the
    // episode posts nothing more when it is turned back on
    @Test func theToggleTurnedOffWithdrawsForTheRestOfTheEpisode() {
        var notice = Notice()
        #expect(notice.step(.start(Self.content(2)), enabled: true) == .post(.slow(fallback: false)))
        #expect(notice.setting(enabled: false) == .withdraw)
        #expect(notice.setting(enabled: true) == nil)
        #expect(notice.step(.update(Self.content(2, fallback: true)), enabled: true) == nil)
        #expect(notice.step(.end, enabled: true) == nil)
        // the next episode posts; an update read with the toggle off withdraws
        #expect(notice.step(.start(Self.content(2)), enabled: true) == .post(.slow(fallback: false)))
        #expect(notice.step(.update(Self.content(3)), enabled: false) == .withdraw)
    }

    // with the toggle off nothing posts, while the dwell still shows its
    // content and the dashboard widget's pill follows it
    @Test func theToggleGatesOnlyTheNotification() throws {
        var policy = TransportDelayActivityPolicy()
        var notice = Notice()
        _ = policy.step(.enabled(true), now: t0)
        _ = policy.step(.reading(Self.slow(2)), now: t0)
        let now = t0.addingTimeInterval(30)
        let action = policy.step(.tick, now: now)
        let start = try #require(action)
        #expect(notice.step(start, enabled: false) == nil)
        let snapshot = TransportDelaySnapshot(
            updatedAt: now,
            tunnelActive: true,
            reading: policy.reading,
            activity: policy.content,
            staleDate: nil
        )
        #expect(SlowInternetWidgetPill.decide(snapshot: snapshot, showsTunnelData: true, now: now)?.level == 2)
    }
}

/**
 * What the app reads of the extension's snapshot, and the toggle's default.
 */
struct TransportDelaySharedStateTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(age: TimeInterval, tunnelActive: Bool = true) -> TransportDelaySnapshot {
        TransportDelaySnapshot(
            updatedAt: now.addingTimeInterval(-age),
            tunnelActive: tunnelActive,
            reading: TransportDelayReading(upQuality: 0.5),
            activity: TransportDelayAttributes.ContentState(reading: TransportDelayReading(upQuality: 0.5), previousLevel: 0),
            staleDate: now.addingTimeInterval(60 - age)
        )
    }

    private func decide(_ snapshot: TransportDelaySnapshot?, enabled: Bool = true) -> TransportDelayAppActivityDecision {
        TransportDelayAppActivityDecision.decide(snapshot: snapshot, enabled: enabled, now: now)
    }

    // the app shows a live tunnel's fresh decision, until its stale date
    @Test func theAppShowsAFreshLiveDecision() {
        let fresh = snapshot(age: 10)
        #expect(decide(fresh) == .show(fresh.activity!, staleDate: now.addingTimeInterval(50)))
        #expect(decide(snapshot(age: 89)) != .leave)
    }

    // a stale snapshot is an extension asleep or killed: the activity is
    // left alone, never ended as if the user had dismissed it
    @Test func theAppLeavesAStaleDecisionAlone() {
        #expect(decide(snapshot(age: 90)) == .leave)
        #expect(decide(snapshot(age: 3600)) == .leave)
    }

    // the toggle off, no snapshot, a stopped tunnel or a hidden policy end it
    @Test func theAppEndsWhatShouldNotShow() {
        #expect(decide(snapshot(age: 10), enabled: false) == .end)
        #expect(decide(nil) == .end)
        #expect(decide(snapshot(age: 0, tunnelActive: false)) == .end)
        #expect(decide(snapshot(age: 3600, tunnelActive: false)) == .end)
        var hidden = snapshot(age: 10)
        hidden.activity = nil
        #expect(decide(hidden) == .end)
    }

    @Test func theSnapshotRoundTrips() throws {
        let original = snapshot(age: 5)
        let data = try WidgetSnapshotStore.encoder.encode(original)
        let decoded = try WidgetSnapshotStore.decoder.decode(TransportDelaySnapshot.self, from: data)
        #expect(decoded == original)
    }

    // on by default (apple/DELAY.md §10 decision 3), and kept where the
    // extension reads it
    @Test func theToggleIsOnByDefault() throws {
        let suite = "network.ur.tests.transport-delay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TransportDelayLiveActivitySetting.isEnabled(in: defaults))
        TransportDelayLiveActivitySetting.setEnabled(false, in: defaults)
        #expect(!TransportDelayLiveActivitySetting.isEnabled(in: defaults))
        TransportDelayLiveActivitySetting.setEnabled(true, in: defaults)
        #expect(TransportDelayLiveActivitySetting.isEnabled(in: defaults))
    }

    // the recovered state clears the numbers and keeps the level it fades from
    @Test func theRecoveredStateFadesFromTheLevel() {
        let content = TransportDelayAttributes.ContentState(reading: TransportDelayReading(downQuality: 1, downDelayMillis: 2600), previousLevel: 3)
        let recovered = content.recoveredState
        #expect(recovered.recovered)
        #expect(recovered.level == 0)
        #expect(recovered.previousLevel == 4)
        #expect(recovered.downDelayMillis == 0)
        #expect(content.settled.previousLevel == 4)
    }
}

/**
 * Spike S1's scripted episode (TransportDelaySimulation), stepped the way the
 * extension steps it: at each change of the script and at each of the
 * policy's deadlines. Within the episode the activity must start, update and
 * end, so one phone test sees each ActivityKit call.
 */
struct TransportDelaySimulationTests {

    typealias Policy = TransportDelayActivityPolicy

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theEpisodeStartsUpdatesAndEnds() {
        var policy = Policy()
        _ = policy.step(.enabled(true), now: t0)
        var summary: [String] = []
        var elapsed: TimeInterval = 0
        while elapsed <= 2 * TransportDelaySimulation.duration {
            let now = t0.addingTimeInterval(elapsed)
            let reading = TransportDelaySimulation.reading(elapsed: elapsed) ?? .normal
            switch policy.step(.reading(reading), now: now) {
            case .start(let content):
                summary.append("\(Int(elapsed)) start \(content.level)")
            case .update(let content):
                summary.append("\(Int(elapsed)) update \(content.recovered ? "recovered" : String(content.level))")
            case .end:
                summary.append("\(Int(elapsed)) end")
            case nil:
                break
            }
            let change = TransportDelaySimulation.nextChange(after: elapsed)
            let deadline = policy.nextDeadline(now: now).map { $0.timeIntervalSince(t0) }
            guard let next = [change, deadline].compactMap({ $0 }).min() else {
                break
            }
            elapsed = next
        }
        #expect(summary == [
            "30 start 2",
            "40 update 4",
            "55 update 3",
            // the numbers' refresh while it waits out its minimum
            "85 update 3",
            "90 update recovered",
            "93 end",
        ])
        #expect(TransportDelaySimulation.duration == 93)
    }

    @Test func theEpisodeIsSlowOnlyForItsSlowPart() {
        #expect(TransportDelaySimulation.reading(elapsed: -1) == nil)
        #expect(TransportDelaySimulation.reading(elapsed: 0)?.level == 2)
        #expect(TransportDelaySimulation.reading(elapsed: 74.9)?.level == 3)
        #expect(TransportDelaySimulation.reading(elapsed: 75) == nil)
        #expect(TransportDelaySimulation.nextChange(after: 75) == nil)
        // a delayed episode's first change is its start
        #expect(TransportDelaySimulation.nextChange(after: -180) == 0)
        // down is the worse direction: its delay is the larger, drawn amber
        let worst = TransportDelaySimulation.reading(elapsed: 40)
        #expect(worst?.downQuality == 1)
        #expect(TransportDelayDirection.worse(upDelayMillis: worst?.upDelayMillis ?? 0, downDelayMillis: worst?.downDelayMillis ?? 0) == .down)
    }

    @Test func theLogMergesBothProcessesKeepsTheNewestAndClears() throws {
        let suite = "network.ur.tests.transport-delay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Log = TransportDelayActivityLog
        Log.append("start failed", key: Log.extensionKey, source: "ext", now: t0.addingTimeInterval(30), in: defaults)
        Log.append("start ok", key: Log.appKey, source: "app", now: t0.addingTimeInterval(31), in: defaults)
        Log.append("adopted an activity already up", key: Log.extensionKey, source: "ext", now: t0.addingTimeInterval(40), in: defaults)
        #expect(Log.entries(in: defaults).map { "\($0.source) \($0.line)" } == [
            "ext start failed",
            "app start ok",
            "ext adopted an activity already up",
        ])
        for i in 0..<(Log.limit + 5) {
            Log.append("line \(i)", key: Log.appKey, source: "app", now: t0.addingTimeInterval(100 + Double(i)), in: defaults)
        }
        let app = Log.entries(in: defaults).filter { $0.source == "app" }
        #expect(app.count == Log.limit)
        #expect(app.last?.line == "line \(Log.limit + 4)")
        Log.clear(now: t0.addingTimeInterval(1_000), in: defaults)
        #expect(Log.entries(in: defaults).isEmpty)
        Log.append("session", key: Log.extensionKey, source: "ext", now: t0.addingTimeInterval(1_001), in: defaults)
        #expect(Log.entries(in: defaults).map(\.line) == ["session"])
    }

    @Test func theEpisodeStartIsKeptInTheGroupDefaults() throws {
        let suite = "network.ur.tests.transport-delay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TransportDelayLiveActivitySetting.simulationStartedAt(in: defaults) == nil)
        TransportDelayLiveActivitySetting.setSimulationStartedAt(t0, in: defaults)
        #expect(TransportDelayLiveActivitySetting.simulationStartedAt(in: defaults) == t0)
        TransportDelayLiveActivitySetting.setSimulationStartedAt(nil, in: defaults)
        #expect(TransportDelayLiveActivitySetting.simulationStartedAt(in: defaults) == nil)
    }
}
