//
//  WidgetReloadThrottleTests.swift
//  networkTests
//
//  The coalescer every widget reload passes through. It is what keeps a
//  chatty source -- providers joining and leaving, a counter ticking every
//  second -- from spending a daily reload budget in a minute, and it had no
//  coverage at all.
//
//  The throttle fires on its own queue against the wall clock, so these wait
//  on the counter reaching a value rather than on a fixed sleep having been
//  long enough: a fixed sleep passes on an idle machine and fails on a busy
//  one, which is the worst kind of test to leave in a suite.
//

import Testing
import Foundation
@testable import URnetwork

struct WidgetReloadThrottleTests {

    /// Short enough to keep the suite quick, long enough that a loaded
    /// machine cannot cross it while a test is between two statements.
    private static let interval: TimeInterval = 0.5

    @Test func aBurstOfRoutineRequestsFiresOnce() async {
        let counter = Counter()
        let throttle = WidgetReloadThrottle(interval: Self.interval) { counter.increment() }

        // the first lands immediately (nothing has fired yet); the rest fall
        // inside the window and collapse into one trailing fire
        for _ in 0..<10 {
            throttle.request()
        }
        #expect(await counter.reaches(1))
        await Self.settle()

        #expect(counter.value <= 2)
    }

    @Test func urgentRequestsAreNotDeferred() async {
        let counter = Counter()
        let throttle = WidgetReloadThrottle(interval: 60) { counter.increment() }

        throttle.request(urgent: true)
        throttle.request(urgent: true)

        #expect(await counter.reaches(2))
    }

    /// A routine request made right after an urgent one waits: `fire` stamps
    /// the same clock either way, so an urgent reload still spaces the next.
    @Test func anUrgentRequestSpacesTheNextRoutineOne() async {
        let counter = Counter()
        let throttle = WidgetReloadThrottle(interval: 60) { counter.increment() }

        throttle.request(urgent: true)
        #expect(await counter.reaches(1))
        throttle.request()
        await Self.settle()

        #expect(counter.value == 1)
    }

    @Test func cancelDropsAPendingReload() async {
        let counter = Counter()
        let throttle = WidgetReloadThrottle(interval: Self.interval) { counter.increment() }

        // wait for the first fire before making the one that must be dropped,
        // so "pending" is not a race with the first request still queued
        throttle.request(urgent: true)
        #expect(await counter.reaches(1))

        throttle.request()
        throttle.cancel()
        await Self.settle()

        #expect(counter.value == 1)
    }

    /// Long enough for a pending work item scheduled at `interval` to have
    /// run if it was going to.
    private static func settle() async {
        try? await Task.sleep(nanoseconds: UInt64(interval * 4 * 1_000_000_000))
    }

    /// The throttle fires on its own queue, so the count needs its own lock.
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

        /// True once the count reaches `target`; false if it never does.
        func reaches(_ target: Int, timeout: TimeInterval = 5) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if target <= value {
                    return true
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
    }
}
