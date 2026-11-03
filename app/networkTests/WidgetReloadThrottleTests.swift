//
//  WidgetReloadThrottleTests.swift
//  networkTests
//
//  The coalescer every widget reload passes through. It is what keeps a
//  chatty source -- providers joining and leaving, a counter ticking every
//  second -- from spending a daily reload budget in a minute, and it had no
//  coverage at all.
//
//  Time moves only when a test moves it (ManualClock). These tests used to run
//  on the wall clock, and waited on the counter rather than a fixed sleep. That
//  still left them racing their own interval: a machine that held a test asleep
//  past the interval made its next routine request go at once, when the test
//  meant it to wait.
//

import Testing
import Foundation
@testable import URnetwork

struct WidgetReloadThrottleTests {

    private static let interval: TimeInterval = 60

    @Test func aBurstOfRoutineRequestsFiresOnce() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval) { counter.increment() }

        // the first lands immediately (nothing has fired yet); the rest fall
        // inside the window and collapse into one trailing fire
        for _ in 0..<10 {
            throttle.request()
        }
        clock.settle()
        #expect(counter.value == 1)
        #expect(clock.waitingCount == 1)

        clock.advance(by: Self.interval - 1)
        #expect(counter.value == 1)

        clock.advance(by: 1)
        #expect(counter.value == 2)
        #expect(clock.waitingCount == 0)
    }

    /// What used to make cancelDropsAPendingReload flake: past the interval
    /// there is nothing to wait for, so a routine request goes at once.
    @Test func aRoutineRequestPastTheIntervalGoesAtOnce() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval) { counter.increment() }

        throttle.request()
        clock.settle()
        clock.advance(by: Self.interval)

        throttle.request()
        clock.settle()
        #expect(counter.value == 2)
        #expect(clock.waitingCount == 0)
    }

    @Test func urgentRequestsAreNotDeferred() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval) { counter.increment() }

        throttle.request(urgent: true)
        throttle.request(urgent: true)
        clock.settle()

        #expect(counter.value == 2)
        #expect(clock.waitingCount == 0)
    }

    /// A routine request made right after an urgent one waits: `fire` stamps
    /// the same clock either way, so an urgent reload still spaces the next.
    @Test func anUrgentRequestSpacesTheNextRoutineOne() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval) { counter.increment() }

        throttle.request(urgent: true)
        clock.settle()
        clock.advance(by: 10)
        throttle.request()
        clock.settle()
        #expect(counter.value == 1)

        // the wait is what is left of the interval since the urgent reload
        clock.advance(by: Self.interval - 11)
        #expect(counter.value == 1)
        clock.advance(by: 1)
        #expect(counter.value == 2)
    }

    /// Any reload covers whatever is waiting: the waiting requests followed
    /// writes that are already on disk.
    @Test func anUrgentReloadCoversAWaitingRoutineOne() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval) { counter.increment() }

        throttle.request()
        throttle.request()
        clock.settle()
        #expect(clock.waitingCount == 1)

        throttle.request(urgent: true)
        clock.settle()
        #expect(counter.value == 2)
        #expect(clock.waitingCount == 0)

        clock.advance(by: Self.interval)
        #expect(counter.value == 2)
    }

    /// The overview reloads with each of the other kinds, and takes the
    /// urgency of the reload it follows from this mark.
    @Test func aRoutineReloadIsMarkedAsOne() {
        let clock = ManualClock()
        let routine = Recorder()
        let throttle = clock.throttle(interval: Self.interval) { routine.record(WidgetReloadThrottle.firingRoutine) }

        // nothing has fired yet, so a routine request goes at once
        throttle.request()
        clock.settle()
        throttle.request(urgent: true)
        clock.settle()
        // this one waits, and is still a routine reload when it runs
        throttle.request()
        clock.settle()
        clock.advance(by: Self.interval)

        #expect(routine.values == [true, false, true])
        #expect(!WidgetReloadThrottle.firingRoutine)
    }

    /// One event reloads two or three kinds; the overview follows each, and
    /// with a delay the urgent requests go as one.
    @Test func urgentRequestsInsideTheDelayGoAsOne() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval, urgentDelay: 1) { counter.increment() }

        throttle.request(urgent: true)
        throttle.request(urgent: true)
        throttle.request(urgent: true)
        clock.settle()
        #expect(counter.value == 0)
        #expect(clock.waitingCount == 1)

        clock.advance(by: 1)
        #expect(counter.value == 1)
        #expect(clock.waitingCount == 0)
    }

    @Test func cancelDropsAPendingReload() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval) { counter.increment() }

        throttle.request(urgent: true)
        clock.settle()
        #expect(counter.value == 1)

        throttle.request()
        clock.settle()
        #expect(clock.waitingCount == 1)

        throttle.cancel()
        clock.settle()
        #expect(clock.waitingCount == 0)

        clock.advance(by: Self.interval)
        #expect(counter.value == 1)
    }

    @Test func cancelDropsAPendingUrgentReload() {
        let clock = ManualClock()
        let counter = Counter()
        let throttle = clock.throttle(interval: Self.interval, urgentDelay: 1) { counter.increment() }

        throttle.request(urgent: true)
        clock.settle()
        #expect(clock.waitingCount == 1)

        throttle.cancel()
        clock.advance(by: 1)
        #expect(counter.value == 0)
    }

    /// The clock everything but these tests uses. Two reloads arrive here
    /// whether the machine lets the second request wait or not, so nothing here
    /// depends on how fast the test runs.
    @Test(.timeLimit(.minutes(1))) func theWallClockRunsADeferredReload() async {
        let (fires, continuation) = AsyncStream<Void>.makeStream()
        let throttle = WidgetReloadThrottle(interval: 0.1) { continuation.yield() }

        throttle.request()
        throttle.request()

        var iterator = fires.makeAsyncIterator()
        await iterator.next()
        await iterator.next()
        withExtendedLifetime(throttle) {}
    }

    /// Stands in for the wall clock and `asyncAfter`. Time moves only in
    /// `advance`, and what falls due runs on the throttle's queue before it
    /// returns. Its state belongs to that queue.
    private final class ManualClock: @unchecked Sendable {
        private let queue = DispatchQueue(label: "network.ur.widget-reload-test")
        private var time = Date(timeIntervalSinceReferenceDate: 0)
        private var waiting: [(runAt: Date, work: DispatchWorkItem)] = []

        func throttle(
            interval: TimeInterval,
            urgentDelay: TimeInterval = 0,
            reload: @escaping () -> Void
        ) -> WidgetReloadThrottle {
            WidgetReloadThrottle(
                interval: interval,
                urgentDelay: urgentDelay,
                queue: queue,
                now: { self.time },
                runAfter: { delay, work in
                    self.waiting.append((runAt: self.time.addingTimeInterval(delay), work: work))
                },
                reload: reload
            )
        }

        /// Runs what the throttle's calls have put on its queue so far.
        func settle() {
            queue.sync {}
        }

        /// Work a real queue would still run: it skips a cancelled item.
        var waitingCount: Int {
            queue.sync { waiting.filter { !$0.work.isCancelled }.count }
        }

        func advance(by delay: TimeInterval) {
            queue.sync {
                time = time.addingTimeInterval(delay)
                while let next = waiting.indices
                    .filter({ waiting[$0].runAt <= time })
                    .min(by: { waiting[$0].runAt < waiting[$1].runAt }) {
                    let work = waiting.remove(at: next).work
                    if !work.isCancelled {
                        work.perform()
                    }
                }
            }
        }
    }

    /// Fires run on the throttle's queue, so the count needs its own lock.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// What each fire saw, in order, behind the same lock.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Bool] = []

        func record(_ value: Bool) {
            lock.lock()
            recorded.append(value)
            lock.unlock()
        }

        var values: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }
}
