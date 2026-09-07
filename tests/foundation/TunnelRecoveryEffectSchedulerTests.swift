import Foundation
import XCTest
@testable import URnetwork

// Actual final-effects scheduler and its composition with the auth owner.
// Explicit queue, monotonic clock and timer delivery control the ordering;
// no elapsed sleeps or claims of NetworkExtension execution are needed.
final class TunnelRecoveryEffectSchedulerTests: XCTestCase {
    func testFinalWakeEffectsDoNotResetTransport() {
        let driver = Driver()
        let scheduler = driver.make()
        defer { scheduler.cancel() }
        scheduler.submit(1, reasons: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.effects, [.init(ticket: 1, reasons: .wake, at: 0)])
        XCTAssertTrue(driver.resets.isEmpty)
        XCTAssertTrue(driver.timers.isEmpty)
    }

    func testFinalPathAndWakeReasonsCoalesceBeforeOneReset() {
        let driver = Driver()
        let scheduler = driver.make()
        defer { scheduler.cancel() }
        scheduler.submit(1, reasons: .path)
        scheduler.submit(1, reasons: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.effects, [.init(ticket: 1, reasons: [.path, .wake], at: 0)])
        XCTAssertEqual(driver.resets.count, 1)
    }

    func testFinalSpacingIsCheckedWhenHeldWorkerActuallyAdmitsReset() {
        let driver = Driver()
        let scheduler = driver.make()
        defer { scheduler.cancel() }
        scheduler.submit(1, reasons: .path)
        driver.now = 100
        driver.queue.drain()
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        XCTAssertEqual(driver.resets.map(\.at), [100])
        XCTAssertEqual(driver.timers.last?.delay, 2)
        driver.now = 102
        driver.timers.last?.fire()
        scheduler.submit(1, reasons: .path)
        // Both the overdue timer and another already-queued path wait behind
        // a held worker. They cannot reset twice when that worker resumes.
        driver.now = 200
        driver.queue.drain()
        XCTAssertEqual(driver.resets.map(\.at), [100, 200])
        XCTAssertEqual(driver.timers.last?.delay, 2)
        driver.now = 201
        driver.timers.last?.fire()
        driver.queue.drain()
        XCTAssertEqual(driver.resets.map(\.at), [100, 200])
        XCTAssertEqual(driver.timers.last?.delay, 1)
        driver.now = 202
        driver.timers.last?.fire()
        driver.queue.drain()
        XCTAssertEqual(driver.resets.map(\.at), [100, 200, 202])
    }

    func testFinalStaleTimerCannotConsumeNewerCoalescedReasons() {
        let driver = Driver()
        let scheduler = driver.make()
        defer { scheduler.cancel() }
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        driver.now = 0.1
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        let oldTimer = driver.timers.last
        scheduler.submit(1, reasons: .wake)
        driver.queue.drain()
        driver.now = 2
        oldTimer?.fire()
        driver.queue.drain()
        XCTAssertEqual(driver.resets.count, 1)
        driver.timers.last?.fire()
        driver.queue.drain()
        XCTAssertEqual(driver.effects.last, .init(ticket: 1, reasons: [.path, .wake], at: 2))
    }

    func testFinalNewDestinationDuringDelayRejectsOldReset() {
        let driver = Driver()
        let scheduler = driver.make()
        defer { scheduler.cancel() }
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        driver.now = 0.1
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        let oldTimer = driver.timers.last
        driver.currentTicket = 2
        scheduler.retireStalePending()
        driver.now = 3
        oldTimer?.fire()
        driver.queue.drain()
        XCTAssertEqual(driver.resets.count, 1)
        scheduler.submit(2, reasons: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.effects.last, .init(ticket: 2, reasons: .wake, at: 3))
        XCTAssertEqual(driver.resets.count, 1)
    }

    func testFinalCancellationRejectsAlreadyDeliveredTimerAndFutureSubmission() {
        let driver = Driver()
        let scheduler = driver.make()
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        driver.now = 2
        driver.timers.last?.fire()
        scheduler.cancel()
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        XCTAssertEqual(driver.resets.count, 1)
    }

    func testHeldAuthAndAlreadyScheduledPathsPreserveFinalSpacingWithoutReadReplay() {
        let driver = Driver()
        let scheduler = driver.make()
        var blocked = true
        var observations = 0
        let auth = TunnelAuthRecoveryContinuation<Int>(
            enqueue: driver.queue.append,
            scheduleDeadline: { _ in {} },
            isCurrent: { $0 == driver.currentTicket },
            observe: { _ in
                observations += 1
                if blocked {
                    throw NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"])
                }
            },
            completed: { scheduler.submit($0, reasons: $1) },
            failed: { _ in XCTFail("held auth was treated as a real read failure") }
        )
        defer { auth.cancel(); scheduler.cancel() }
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        driver.now = 0.1
        auth.request(1, reason: [.path, .wake])
        driver.queue.drain()
        let nextScheduledPath = { auth.request(1, reason: .path) }
        nextScheduledPath()
        driver.queue.drain()
        XCTAssertEqual(observations, 2)
        blocked = false
        auth.settled()
        driver.queue.drain()
        XCTAssertEqual(observations, 3)
        XCTAssertEqual(driver.resets.map(\.at), [0])
        driver.now = 2
        driver.timers.last?.fire()
        nextScheduledPath()
        driver.now = 100
        driver.queue.drain()
        XCTAssertEqual(observations, 4, "only the actual new path may cause another observation")
        XCTAssertEqual(driver.resets.map(\.at), [0, 100])
        XCTAssertEqual(driver.resets.last?.reasons, [.path, .wake])
        driver.now = 102
        driver.timers.last?.fire()
        driver.queue.drain()
        XCTAssertEqual(observations, 4, "waiting out spacing must not replay auth or selection")
        XCTAssertEqual(driver.resets.map(\.at), [0, 100, 102])
        XCTAssertEqual(driver.resets.last?.reasons, .path)
    }

    func testFinalRetirementOutsideLockCheckCannotEraseConcurrentNewSlot() {
        let driver = Driver()
        let current = TicketOwner(1)
        let barrier = ObservationBarrier()
        driver.currentOverride = { ticket in barrier.pauseIfArmed(); return current.value == ticket }
        let scheduler = driver.make()
        defer { scheduler.cancel(); barrier.release.signal() }
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        driver.now = 0.1
        scheduler.submit(1, reasons: .path)
        driver.queue.drain()
        barrier.arm()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { scheduler.retireStalePending(); finished.signal() }
        guard barrier.entered.wait(timeout: .now() + 5) == .success else {
            return XCTFail("final retirement did not reach its outside-lock check")
        }
        current.set(2)
        scheduler.submit(2, reasons: .path)
        driver.queue.drain()
        barrier.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        driver.now = 2
        driver.timers.last?.fire()
        driver.queue.drain()
        XCTAssertEqual(driver.resets.map(\.ticket), [1, 2])
        XCTAssertEqual(driver.resets.map(\.at), [0, 2])
    }

    private struct Effect: Equatable {
        let ticket: Int
        let reasons: TunnelDestinationRecoveryReason
        let at: TimeInterval
    }
    private struct Timer {
        let delay: TimeInterval
        let fire: () -> Void
    }
    private final class Driver {
        let queue = Queue()
        var now: TimeInterval = 0
        var currentTicket = 1
        var currentOverride: ((Int) -> Bool)?
        var effects: [Effect] = []
        var timers: [Timer] = []
        var resets: [Effect] { effects.filter { $0.reasons.contains(.path) } }
        func make() -> TunnelRecoveryEffectScheduler<Int> {
            TunnelRecoveryEffectScheduler(
                enqueue: queue.append,
                schedule: { delay, fire in self.timers.append(.init(delay: delay, fire: fire)); return {} },
                now: { self.now }, minimumInterval: 2,
                isCurrent: { self.currentOverride?($0) ?? ($0 == self.currentTicket) },
                perform: { self.effects.append(.init(ticket: $0, reasons: $1, at: self.now)) }
            )
        }
    }
    private final class Queue {
        private let lock = NSLock()
        private var work: [() -> Void] = []
        func append(_ action: @escaping () -> Void) { lock.lock(); work.append(action); lock.unlock() }
        private func take() -> (() -> Void)? {
            lock.lock()
            defer { lock.unlock() }
            return work.isEmpty ? nil : work.removeFirst()
        }
        func drain() {
            var count = 0
            while let action = take() {
                count += 1
                guard count <= 64 else { XCTFail("final effects entered a busy retry"); return }
                action()
            }
        }
    }
    private final class TicketOwner {
        private let lock = NSLock()
        private var ticket: Int
        init(_ ticket: Int) { self.ticket = ticket }
        var value: Int { lock.lock(); defer { lock.unlock() }; return ticket }
        func set(_ ticket: Int) { lock.lock(); self.ticket = ticket; lock.unlock() }
    }
    private final class ObservationBarrier {
        private let lock = NSLock()
        private var armed = false
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func arm() { lock.lock(); armed = true; lock.unlock() }
        func pauseIfArmed() {
            lock.lock()
            let pause = armed
            armed = false
            lock.unlock()
            if pause { entered.signal(); release.wait() }
        }
    }
}
