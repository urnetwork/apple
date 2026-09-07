import Foundation
import XCTest
@testable import URnetwork

// The actual production owner, with explicit queue and deadline boundaries.
// Injected publication/error ordering is native ownership evidence, not a claim
// that a Go refresh was held. Separate SDK tests hold that real publisher.
final class TunnelAuthRecoveryContinuationTests: XCTestCase {
    func testRecoveryHealthyRequestRunsOnlyOnOwnedQueue() {
        let driver = Driver()
        driver.authSettled = true
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        XCTAssertEqual(driver.attempts, 0)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.completions, [.init(ticket: 1, reasons: .wake)])
        XCTAssertEqual(driver.queue.count, 0)
    }

    func testRecoveryHealthyRefreshWithoutPendingRequestDoesNothing() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.settled()
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 0)
        XCTAssertTrue(driver.completions.isEmpty)
        XCTAssertTrue(driver.deadlines.isEmpty)
    }

    func testRecoveryEventBeforeObservationDoesNotReplaySuccess() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .path)
        driver.authSettled = true
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.completions.count, 1)
        XCTAssertEqual(driver.transportChanges, 1)
    }

    func testRecoveryWaitsWithoutPollingUntilPublication() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.queue.count, 0)
        XCTAssertTrue(driver.completions.isEmpty)
        driver.authSettled = true
        recovery.settled()
        XCTAssertEqual(driver.attempts, 1, "SDK event cannot perform recovery inline")
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.completions.count, 1)
        XCTAssertEqual(driver.transportChanges, 0)
    }

    func testRecoveryPublicationDuringFailedObservationCannotBeLost() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        driver.observe = {
            if driver.attempts == 1 {
                recovery.settled()
                recovery.settled()
                throw Driver.unsettled
            }
        }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.completions.count, 1)
        XCTAssertEqual(driver.queue.count, 0)
    }

    func testRecoveryDelayedPublicationAfterDeadlineRetainsPendingReason() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .path)
        driver.queue.drain()
        driver.deadlines.last?()
        driver.deadlines.last?()
        XCTAssertEqual(driver.phases, ["waiting", "timeout"])
        XCTAssertEqual(driver.queue.count, 0)
        driver.authSettled = true
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.transportChanges, 1)
        XCTAssertEqual(driver.completions.count, 1)
    }

    func testRecoveryDeadlineDuringObservationNeverStartsOverlappingWork() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        var inside = false
        driver.observe = {
            XCTAssertFalse(inside)
            inside = true
            defer { inside = false }
            if driver.attempts == 1 {
                driver.deadlines.last?()
                recovery.settled()
                driver.queue.drain()
                XCTAssertEqual(driver.attempts, 1, "timeout cannot preempt an admitted SDK call")
                throw Driver.unsettled
            }
        }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.completions.count, 1)
        XCTAssertEqual(driver.phases.filter { $0 == "timeout" }.count, 1)
    }

    func testRecoveryRepeatedWakeAndPathRequestsCoalesce() {
        let driver = Driver()
        driver.authSettled = true
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        recovery.request(1, reason: .path)
        recovery.request(1, reason: .wakeGrace)
        XCTAssertEqual(driver.queue.count, 1)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.completions, [.init(ticket: 1, reasons: [.wake, .path, .wakeGrace])])
        XCTAssertEqual(driver.transportChanges, 1)
    }

    func testRecoveryNewAllowedWakeCanResumeAfterDeadlineWithoutPolling() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        driver.deadlines.last?()
        driver.authSettled = true
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.completions.count, 1)
        XCTAssertEqual(driver.transportChanges, 0)
    }

    func testRecoveryRealReadFailureDoesNotWaitOrExposePrivateError() {
        let driver = Driver()
        driver.observe = { throw Driver.privateReadError }
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        recovery.settled()
        driver.deadlines.last?()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.failures, [1])
        XCTAssertTrue(driver.phases.isEmpty)
        XCTAssertFalse(driver.phases.joined().contains("private-marker"))
    }

    func testRecoveryPublicationCannotReclassifyRealReadFailure() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        driver.observe = { recovery.settled(); throw Driver.privateReadError }
        recovery.request(1, reason: .path)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.failures, [1])
        XCTAssertEqual(driver.transportChanges, 0)
        XCTAssertEqual(driver.queue.count, 0)
    }

    func testRecoveryNewDestinationRetiresBeforeQueuedObservation() {
        let driver = Driver()
        driver.authSettled = true
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.currentTicket = 2
        recovery.retireStalePending()
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 0)
        XCTAssertTrue(driver.completions.isEmpty)
    }

    func testRecoveryExplicitDisconnectRetiresParkedConnect() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        driver.currentTicket = 2
        recovery.retireStalePending()
        driver.authSettled = true
        recovery.settled()
        driver.deadlines.first?()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertTrue(driver.completions.isEmpty)
        XCTAssertEqual(driver.transportChanges, 0)
    }

    func testRecoveryRetirementPreservesAlreadyQueuedNewDestination() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        driver.currentTicket = 2
        driver.authSettled = true
        recovery.request(2, reason: .wake)
        recovery.retireStalePending()
        driver.queue.drain()
        XCTAssertEqual(driver.completions, [.init(ticket: 2, reasons: .wake)])
    }

    func testRecoveryCancelledBeforeQueuedObservationDoesNoSdkWork() {
        let driver = Driver()
        let recovery = driver.make()
        recovery.request(1, reason: .path)
        recovery.cancel()
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 0)
        XCTAssertTrue(driver.completions.isEmpty)
    }

    func testRecoveryCancellationDuringObservationRejectsLateCompletion() {
        let driver = Driver()
        let recovery = driver.make()
        driver.observe = { recovery.cancel(); recovery.settled() }
        recovery.request(1, reason: .path)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertTrue(driver.completions.isEmpty)
        XCTAssertEqual(driver.transportChanges, 0)
    }

    func testRecoveryHeldOldObservationCannotPublishForNewDestination() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        driver.observe = {
            if driver.attempts == 1 {
                driver.currentTicket = 2
                recovery.retireStalePending()
                recovery.request(2, reason: .wake)
                recovery.settled()
                driver.queue.drain()
                XCTAssertEqual(driver.attempts, 1)
                throw Driver.unsettled
            }
        }
        recovery.request(1, reason: .path)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.completions, [.init(ticket: 2, reasons: .wake)])
        XCTAssertEqual(driver.transportChanges, 0)
    }

    func testRecoveryLateOldOwnerPublicationCannotReadReplacement() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        driver.currentTicket = 2
        driver.authSettled = true
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertTrue(driver.completions.isEmpty)
    }

    func testRecoveryDelayedOldRetirementCannotEraseNewPendingTicket() {
        let driver = Driver()
        let recovery = driver.make()
        defer { recovery.cancel() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        driver.currentTicket = 2
        // Old callback has reserved ticket2, but its cleanup is held until a
        // newer callback/request has reserved ticket3 and parked on auth.
        let delayedOldRetirement = { recovery.retireStalePending() }
        driver.currentTicket = 3
        recovery.request(3, reason: .wake)
        driver.queue.drain()
        delayedOldRetirement()
        driver.authSettled = true
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.completions, [.init(ticket: 3, reasons: .wake)])
        XCTAssertEqual(driver.transportChanges, 0)
    }

    func testRecoveryConcurrentSignalsAndCancellationRetainSingleOwner() {
        let driver = Driver()
        let recovery = driver.make()
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        let group = DispatchGroup()
        for index in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                if index.isMultiple(of: 2) { recovery.settled() }
                else { recovery.cancel() }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertTrue(driver.completions.isEmpty)
    }

    func testRecoveryRetirementOwnershipCheckCannotEraseConcurrentNewGeneration() {
        let driver = Driver()
        let current = TicketOwner(1)
        let barrier = ObservationBarrier()
        driver.currentOverride = { ticket in barrier.pauseIfArmed(); return current.value == ticket }
        let recovery = driver.make()
        defer { recovery.cancel(); barrier.release.signal() }
        recovery.request(1, reason: .wake)
        driver.queue.drain()
        barrier.arm()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { recovery.retireStalePending(); finished.signal() }
        guard barrier.entered.wait(timeout: .now() + 5) == .success else {
            return XCTFail("retirement did not reach its outside-lock ownership check")
        }
        current.set(2)
        recovery.request(2, reason: .wake)
        barrier.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        driver.authSettled = true
        recovery.settled()
        driver.queue.drain()
        XCTAssertEqual(driver.completions, [.init(ticket: 2, reasons: .wake)])
    }

    private struct Completion: Equatable {
        let ticket: Int
        let reasons: TunnelDestinationRecoveryReason
    }

    private final class Driver {
        static var unsettled: NSError {
            NSError(domain: "go", code: 1, userInfo: [NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"])
        }
        static var privateReadError: NSError {
            NSError(domain: "private-marker", code: 7, userInfo: [NSLocalizedDescriptionKey: "/private-marker/token/read"])
        }
        let queue = Queue()
        var authSettled = false
        var currentTicket = 1
        var attempts = 0
        var transportChanges = 0
        var completions: [Completion] = []
        var failures: [Int] = []
        var phases: [String] = []
        var deadlines: [() -> Void] = []
        var observe: (() throws -> Void)?
        var currentOverride: ((Int) -> Bool)?

        func make() -> TunnelAuthRecoveryContinuation<Int> {
            TunnelAuthRecoveryContinuation(
                enqueue: queue.append,
                scheduleDeadline: { expire in self.deadlines.append(expire); return {} },
                isCurrent: { self.currentOverride?($0) ?? ($0 == self.currentTicket) },
                observe: { _ in
                    self.attempts += 1
                    if let observe = self.observe { try observe() }
                    else if !self.authSettled { throw Self.unsettled }
                },
                completed: { ticket, reasons in
                    self.completions.append(.init(ticket: ticket, reasons: reasons))
                    if reasons.contains(.path) { self.transportChanges += 1 }
                },
                failed: { self.failures.append($0) },
                report: { _, phase in self.phases.append(phase == .waiting ? "waiting" : "timeout") }
            )
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

    private final class Queue {
        private let lock = NSLock()
        private var work: [() -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return work.count }
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
                guard count <= 64 else { XCTFail("recovery queue entered a busy retry loop"); return }
                action()
            }
        }
    }
}
