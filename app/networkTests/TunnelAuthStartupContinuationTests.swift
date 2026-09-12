import Foundation
import XCTest
@testable import URnetwork

// Actual production continuation with explicit event/queue/deadline controls.
// No sleeps or fabricated claim about SDK publication: the separate SDK test
// holds its real refresh lease and proves the device event follows storage.
final class TunnelAuthStartupContinuationTests: XCTestCase {
    func testHealthyStartupSubscribesBeforeSynchronousFirstObservation() {
        let driver = Driver()
        driver.authSettled = true
        let startup = driver.make()
        startup.start()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.events, ["subscribe", "deadline", "observe", "unsubscribe", "cancel-deadline", "success"])
        XCTAssertEqual(driver.queue.count, 0)
    }

    func testUnsettledStartupWaitsForActualEventWithoutHotRetry() {
        let driver = Driver()
        let startup = driver.make()
        startup.start()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.queue.count, 0)
        XCTAssertTrue(driver.results.isEmpty)
        driver.authSettled = true
        driver.signal?()
        XCTAssertEqual(driver.attempts, 1, "SDK callback cannot run Load inline")
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.successes, 1)
    }

    func testSettlementDuringFailedReadCannotBeLostBeforeParking() {
        let driver = Driver()
        let startup = driver.make {
            if driver.attempts == 1 {
                driver.signal?()
                XCTAssertEqual(driver.attempts, 1)
                throw Driver.unsettled
            }
        }
        startup.start()
        XCTAssertEqual(driver.queue.count, 1)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.successes, 1)
    }

    func testSettlementDuringSubscriptionIsConsumedByFirstRead() {
        let driver = Driver()
        driver.onSubscribe = { driver.authSettled = true; driver.signal?() }
        let startup = driver.make()
        startup.start()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.successes, 1)
        XCTAssertEqual(driver.queue.count, 0)
    }

    func testRepeatedSettlementEdgesCoalesceOneQueuedAttempt() {
        let driver = Driver()
        let startup = driver.make()
        startup.start()
        driver.authSettled = true
        driver.signal?()
        driver.signal?()
        XCTAssertEqual(driver.queue.count, 1)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 2)
        XCTAssertEqual(driver.successes, 1)
    }

    func testRealReadFailureTerminatesInsteadOfWaitingForRefresh() {
        let driver = Driver()
        let startup = driver.make {
            throw NSError(domain: "private-marker", code: 7, userInfo: [NSLocalizedDescriptionKey: "/private-marker/read"])
        }
        startup.start()
        XCTAssertTrue(driver.results.isEmpty, "failure cleanup is queued off the lifecycle caller")
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.results.count, 1)
        XCTAssertEqual(driver.successes, 0)
        XCTAssertFalse(driver.events.contains("waiting"))
        XCTAssertFalse(driver.events.joined().contains("private-marker"))
    }

    func testCancellationRejectsQueuedRetryAndCompletesOnce() {
        let driver = Driver()
        let startup = driver.make()
        startup.start()
        driver.signal?()
        startup.cancel()
        driver.authSettled = true
        driver.signal?()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.results.count, 1)
        XCTAssertEqual(driver.successes, 0)
        XCTAssertEqual(driver.events.filter { $0 == "unsubscribe" }.count, 1)
    }

    func testOwnerRetirementCancelsItsWaitingStartup() {
        let driver = Driver()
        let holder = TunnelRecoverySession<String, String>()
        let ticket = holder.begin(owner: "old", savedLocationHasCurrentOwner: true)
        let startup = driver.make()
        XCTAssertTrue(holder.installAuthStartup(startup, ticket: ticket))
        startup.start()
        let newer = holder.begin(owner: "new", savedLocationHasCurrentOwner: true)
        driver.authSettled = true
        driver.signal?()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.successes, 0)
        XCTAssertTrue(holder.isCurrent(newer))
        XCTAssertFalse(holder.clearAuthStartup(ticket))
    }

    func testDeadlineRetiresWaitingStartupAndIgnoresLaterSettlement() {
        let driver = Driver()
        let startup = driver.make()
        startup.start()
        driver.expire?()
        XCTAssertTrue(driver.results.isEmpty)
        driver.authSettled = true
        driver.signal?()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.results.count, 1)
        guard let result = driver.results.first, case .failure(let error) = result else { return XCTFail("deadline must fail") }
        XCTAssertTrue(error is TunnelAuthStartupError)
    }

    func testDeadlineDuringSdkCallDefersCleanupUntilCallReturns() {
        let driver = Driver()
        var insideObservation = false
        let startup = driver.make {
            insideObservation = true
            driver.expire?()
            driver.queue.drain()
            XCTAssertTrue(driver.results.isEmpty, "cleanup cannot race admitted SDK work")
            insideObservation = false
        }
        startup.start()
        driver.queue.drain()
        XCTAssertFalse(insideObservation)
        XCTAssertEqual(driver.successes, 0)
        XCTAssertEqual(driver.results.count, 1)
    }

    func testChangedOwnerBeforeEventPreventsAnotherPreferenceRead() {
        let driver = Driver()
        let startup = driver.make()
        startup.start()
        driver.current = false
        driver.authSettled = true
        driver.signal?()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.successes, 0)
        XCTAssertEqual(driver.results.count, 1)
    }

    func testNewDisconnectIsReobservedBeforeLoadOnSettlement() {
        let driver = Driver()
        var intent: TunnelDestinationIntent = .connect
        var saved: String? = "old-current"
        var enabled = false
        let startup = driver.make {
            guard driver.authSettled else { throw Driver.unsettled }
            let loaded: String? = try loadTunnelPreferences(
                intent: intent, loadOwnedPreferences: true, isCurrent: { driver.current },
                persistDisconnect: { saved = nil; driver.events.append("disconnect") },
                load: { XCTAssertNil(saved); driver.events.append("load"); return "loaded" },
                enableAutoSave: { enabled = true; driver.events.append("autosave") }
            )
            XCTAssertEqual(loaded, "loaded")
        }
        startup.start()
        intent = .disconnect
        driver.authSettled = true
        driver.signal?()
        driver.queue.drain()
        XCTAssertTrue(enabled)
        XCTAssertNil(saved)
        XCTAssertEqual(driver.events.filter { ["disconnect", "load", "autosave"].contains($0) }, ["disconnect", "load", "autosave"])
        XCTAssertEqual(driver.successes, 1)
    }

    func testAuthLogoutDuringSubscriptionCancelsBeforeFirstRead() {
        let driver = Driver()
        driver.onSubscribe = { driver.reject?() }
        let startup = driver.make()
        startup.start()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 0)
        XCTAssertEqual(driver.successes, 0)
        XCTAssertEqual(driver.results.count, 1)
    }

    func testRepeatedStartAndLateDeadlineCannotCompleteTwice() {
        let driver = Driver()
        driver.authSettled = true
        let startup = driver.make()
        startup.start()
        startup.start()
        driver.expire?()
        startup.cancel()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.results.count, 1)
        XCTAssertEqual(driver.successes, 1)
    }

    func testCancelledBeforeStartDoesNotSubscribeOrObserve() {
        let driver = Driver()
        let startup = driver.make()
        startup.cancel()
        startup.start()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 0)
        XCTAssertEqual(driver.events, ["failure"])
        XCTAssertEqual(driver.results.count, 1)
    }

    func testRetirementDuringSubscriptionInstallationCancelsReturnedSubscription() {
        let driver = Driver()
        let holder = TunnelRecoverySession<String, String>()
        let ticket = holder.begin(owner: "current", savedLocationHasCurrentOwner: true)
        driver.onSubscribe = { holder.retire(ticket) }
        let startup = driver.make()
        XCTAssertTrue(holder.installAuthStartup(startup, ticket: ticket))
        startup.start()
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 0)
        XCTAssertEqual(driver.results.count, 1)
        XCTAssertEqual(driver.events.filter { $0 == "unsubscribe" }.count, 1)
        XCTAssertEqual(driver.events.filter { $0 == "cancel-deadline" }.count, 1)
    }

    func testConcurrentSettlementAndCancellationKeepOneTerminalOwner() {
        let driver = Driver()
        let startup = driver.make()
        startup.start()
        let signal = driver.signal
        let group = DispatchGroup()
        for index in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                if index.isMultiple(of: 2) { signal?() }
                else { startup.cancel() }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        driver.queue.drain()
        XCTAssertEqual(driver.attempts, 1)
        XCTAssertEqual(driver.results.count, 1)
        XCTAssertEqual(driver.successes, 0)
    }

    func testUnchangedSharedDisconnectFinishesOnAdmittedStackWithoutSecondEnqueue() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            let startup = driver.make(finishAdmission: fixture.admission()) { try fixture.observe() }
            startup.start()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertTrue(driver.results.isEmpty)
            XCTAssertEqual(fixture.queue.count, 1)
            XCTAssertFalse(driver.events.contains("cancel-deadline"))
            fixture.queue.enqueue {
                XCTAssertEqual(driver.successes, 1, "success must finish before the next main block")
                XCTAssertEqual(fixture.queue.count, 0, "finish must not enqueue a second main hop")
            }
            fixture.queue.drain()
            XCTAssertEqual(fixture.reads, 1)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.queue.count, 0)
            XCTAssertEqual(driver.events.filter { $0 == "unsubscribe" }.count, 1)
        }
    }

    func testChangedSharedIntentReconcilesOnWorkerWithOriginalSubscriptionAndDeadline() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            let startup = driver.make(finishAdmission: fixture.admission()) { try fixture.observe() }
            startup.start()
            fixture.record(connect: true)
            fixture.queue.drain()
            XCTAssertEqual(driver.attempts, 1, "main admission must not run destination work")
            XCTAssertEqual(driver.queue.count, 1)
            driver.signal?()
            driver.signal?()
            XCTAssertEqual(driver.queue.count, 1)
            XCTAssertFalse(driver.events.contains("waiting"))
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 2)
            XCTAssertEqual(fixture.queue.count, 1)
            XCTAssertEqual(driver.events.filter { $0 == "subscribe" }.count, 1)
            XCTAssertEqual(driver.events.filter { $0 == "deadline" }.count, 1)
            XCTAssertFalse(driver.events.contains("cancel-deadline"))
            fixture.queue.enqueue {
                XCTAssertEqual(driver.successes, 1)
                XCTAssertEqual(fixture.queue.count, 0, "success must stay on its admitted stack")
            }
            fixture.queue.drain()
            XCTAssertEqual(fixture.reads, 2)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.queue.count, 0)
        }
    }

    func testCancellationCleansAndReleasesCapturesWithoutDrainingQueuedFinish() throws {
        try assertQueuedFinishTerminates(deadline: false)
    }

    func testDeadlineCleansAndReleasesCapturesWithoutDrainingQueuedFinish() throws {
        try assertQueuedFinishTerminates(deadline: true)
    }

    func testCancellationDuringSharedIntentReadJoinsBeforeWorkerCleanup() throws {
        try assertFinishReadJoins(deadline: false)
    }

    func testDeadlineDuringSharedIntentReadJoinsBeforeWorkerCleanup() throws {
        try assertFinishReadJoins(deadline: true)
    }

    func testMalformedSharedIntentAtQueuedFinishFailsWithoutAnotherObservation() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            let startup = driver.make(finishAdmission: fixture.admission()) { try fixture.observe() }
            startup.start()
            fixture.defaults.set("not-an-intent-record", forKey: TunnelIntentStore.key)
            fixture.queue.drain()
            XCTAssertTrue(driver.results.isEmpty, "read failure must leave the main admission stack")
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.successes, 0)
            guard case .failure(let error)? = driver.results.first,
                  case TunnelIntentStorageError.malformed = error else {
                return XCTFail("malformed intent must remain a checked failure")
            }
        }
    }

    func testUnavailableSharedIntentAtQueuedFinishFailsClosed() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            let admission = fixture.holder.startupFinishAdmission(
                ticket: fixture.ticket, enqueue: fixture.queue.enqueue,
                readIntent: { try TunnelIntentStore.loadChecked(from: nil) }
            )
            let startup = driver.make(finishAdmission: admission) { try fixture.observe() }
            startup.start()
            fixture.queue.drain()
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.successes, 0)
            guard case .failure(let error)? = driver.results.first,
                  case TunnelIntentStorageError.unavailable = error else {
                return XCTFail("unavailable intent store must not become absence")
            }
        }
    }

    func testRetiredRecoveryOwnerRejectsQueuedFinishBeforeSharedRead() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            let startup = driver.make(finishAdmission: fixture.admission()) { try fixture.observe() }
            XCTAssertTrue(fixture.holder.installAuthStartup(startup, ticket: fixture.ticket))
            startup.start()
            let replacement = fixture.holder.begin(owner: "replacement", savedLocationHasCurrentOwner: true)
            driver.queue.drain()
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertTrue(fixture.holder.isCurrent(replacement))
            fixture.queue.drain()
            XCTAssertEqual(fixture.reads, 0)
            XCTAssertEqual(driver.successes, 0)
            XCTAssertEqual(driver.attempts, 1)
        }
    }

    func testDestinationChangedDuringFinishReadRejectsOriginatingAdmission() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            fixture.duringRead = {
                XCTAssertNotNil(fixture.holder.noteDestinationChange(ticket: fixture.ticket))
            }
            let startup = driver.make(finishAdmission: fixture.admission()) { try fixture.observe() }
            startup.start()
            fixture.queue.drain()
            driver.queue.drain()
            XCTAssertEqual(fixture.reads, 1)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.successes, 0)
            XCTAssertEqual(driver.attempts, 1)
            guard case .failure(let error)? = driver.results.first,
                  case TunnelLocalAuthIdentityError.superseded = error else {
                return XCTFail("the destination ticket must fence the checked read")
            }
        }
    }

    func testOriginalDeadlineDuringDestinationRetryJoinsBeforeFailureDelivery() throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            let startup = driver.make(finishAdmission: fixture.admission()) {
                if driver.attempts == 2 {
                    driver.expire?()
                    driver.queue.drain()
                    XCTAssertTrue(driver.results.isEmpty, "an executing destination read must join")
                }
                try fixture.observe()
            }
            startup.start()
            fixture.record(connect: true)
            fixture.queue.drain()
            driver.queue.drain()
            XCTAssertEqual(driver.attempts, 2)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.successes, 0)
            XCTAssertEqual(driver.events.filter { $0 == "deadline" }.count, 1)
            XCTAssertEqual(fixture.queue.count, 0)
            guard case .failure(let error)? = driver.results.first else { return XCTFail("deadline must win") }
            XCTAssertTrue(error is TunnelAuthStartupError)
        }
    }

    private func assertQueuedFinishTerminates(deadline: Bool) throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            var cleaned = 0
            var cleanup: TunnelStartupCleanup? = TunnelStartupCleanup {
                XCTAssertTrue(fixture.holder.isCurrent(fixture.ticket), "cleanup can reenter the owner")
                cleaned += 1
            }
            weak var capturedCleanup = cleanup
            driver.onCompletion = { _ in capturedCleanup?.cleanUpNow() }
            func makeStartup(capturing cleanup: TunnelStartupCleanup) -> TunnelAuthStartupContinuation {
                driver.make(finishAdmission: fixture.admission()) {
                    withExtendedLifetime(cleanup) {}
                    try fixture.observe()
                }
            }
            let startup = makeStartup(capturing: try XCTUnwrap(cleanup))
            startup.start()
            cleanup = nil
            XCTAssertNotNil(capturedCleanup)
            XCTAssertEqual(fixture.queue.count, 1)
            if deadline { driver.expire?() } else { startup.cancel() }
            driver.queue.drain()
            XCTAssertEqual(cleaned, 1)
            XCTAssertNil(capturedCleanup, "queued finish must release retired configuration/SDK captures")
            XCTAssertEqual(fixture.queue.count, 1, "main is deliberately still held")
            XCTAssertEqual(fixture.reads, 0)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.successes, 0)
            guard case .failure(let error)? = driver.results.first else { return XCTFail("cancellation must fail") }
            if deadline { XCTAssertTrue(error is TunnelAuthStartupError) }
            else if case TunnelLocalAuthIdentityError.superseded = error {} else { XCTFail("wrong cancellation error") }
            driver.signal?()
            fixture.queue.drain()
            driver.queue.drain()
            XCTAssertEqual(fixture.reads, 0)
            XCTAssertEqual(cleaned, 1)
            XCTAssertEqual(driver.attempts, 1)
            XCTAssertEqual(driver.results.count, 1)
        }
    }

    private func assertFinishReadJoins(deadline: Bool) throws {
        try withFinishFixture { fixture in
            let driver = Driver()
            var reading = false
            var cleaned = 0
            let cleanup = TunnelStartupCleanup {
                XCTAssertFalse(reading, "cleanup must join an admitted shared-intent read")
                XCTAssertTrue(fixture.holder.isCurrent(fixture.ticket))
                cleaned += 1
            }
            driver.onCompletion = { _ in cleanup.cleanUpNow() }
            let startup = driver.make(finishAdmission: fixture.admission()) { try fixture.observe() }
            fixture.duringRead = {
                reading = true
                XCTAssertTrue(fixture.holder.isCurrent(fixture.ticket), "read is outside the owner lock")
                if deadline { driver.expire?() } else { startup.cancel() }
                driver.queue.drain()
                XCTAssertTrue(driver.results.isEmpty)
                XCTAssertEqual(cleaned, 0)
                reading = false
            }
            startup.start()
            fixture.queue.drain()
            XCTAssertEqual(fixture.reads, 1)
            XCTAssertEqual(cleaned, 0)
            driver.queue.drain()
            XCTAssertEqual(cleaned, 1)
            XCTAssertEqual(driver.results.count, 1)
            XCTAssertEqual(driver.successes, 0)
            XCTAssertEqual(fixture.queue.count, 0)
            fixture.duringRead = nil
        }
    }

    private func withFinishFixture(_ body: (FinishFixture) throws -> Void) throws {
        let fixture = try FinishFixture()
        defer {
            fixture.holder.retire()
            fixture.duringRead = nil
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try body(fixture)
    }

    private final class FinishFixture {
        let holder = TunnelRecoverySession<String, TunnelIntent>()
        let ticket: TunnelRecoverySession<String, TunnelIntent>.Ticket
        let queue = Queue()
        let suiteName = "network.ur.tests.startup-finish." + UUID().uuidString
        let defaults: UserDefaults
        var reads = 0
        var duringRead: (() -> Void)?

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            ticket = holder.begin(owner: "current", savedLocationHasCurrentOwner: true)
            record(connect: false)
        }

        func record(connect: Bool) {
            TunnelIntentStore.record(
                connect: connect, source: TunnelIntentStore.sourceApp,
                at: Date(timeIntervalSince1970: connect ? 1_800_000_101 : 1_800_000_100), in: defaults
            )
        }

        func observe() throws {
            let intent = try TunnelIntentStore.loadChecked(from: defaults)
            let state = try XCTUnwrap(holder.snapshot(ticket: ticket))
            XCTAssertTrue(holder.acceptDestination(state.destinationTicket, present: false, observedIntent: intent))
        }

        func admission() -> TunnelAuthStartupContinuation.FinishAdmission {
            holder.startupFinishAdmission(ticket: ticket, enqueue: queue.enqueue, readIntent: {
                self.reads += 1
                self.duringRead?()
                return try TunnelIntentStore.loadChecked(from: self.defaults)
            })
        }
    }

    private final class Queue {
        private let lock = NSLock()
        private var work: [() -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return work.count }
        func enqueue(_ block: @escaping () -> Void) { lock.lock(); work.append(block); lock.unlock() }
        func drain() {
            for _ in 0..<100 {
                lock.lock()
                let block = work.isEmpty ? nil : work.removeFirst()
                lock.unlock()
                guard let block else { return }
                block()
            }
            XCTFail("unexpected unbounded continuation work")
        }
    }

    private final class Driver {
        static let unsettled = NSError(
            domain: "sdk", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"]
        )
        let queue = Queue()
        var events: [String] = []
        var attempts = 0
        var results: [Result<Void, Error>] = []
        var authSettled = false
        var current = true
        var signal: (() -> Void)?
        var reject: (() -> Void)?
        var expire: (() -> Void)?
        var onSubscribe: (() -> Void)?
        var onCompletion: ((Result<Void, Error>) -> Void)?
        var successes: Int { results.filter { if case .success = $0 { return true }; return false }.count }

        func make(
            finishAdmission: TunnelAuthStartupContinuation.FinishAdmission? = nil,
            observe: (() throws -> Void)? = nil
        ) -> TunnelAuthStartupContinuation {
            TunnelAuthStartupContinuation(
                enqueue: queue.enqueue,
                subscribe: { signal, reject in
                    self.events.append("subscribe")
                    self.signal = signal
                    self.reject = reject
                    self.onSubscribe?()
                    return { self.events.append("unsubscribe") }
                },
                scheduleDeadline: { expire in
                    self.events.append("deadline")
                    self.expire = expire
                    return { self.events.append("cancel-deadline") }
                },
                isCurrent: { self.current },
                observe: {
                    self.attempts += 1
                    self.events.append("observe")
                    if let observe { try observe() }
                    else if !self.authSettled { throw Self.unsettled }
                },
                finishAdmission: finishAdmission,
                waiting: { self.events.append("waiting") },
                completion: { result in
                    self.results.append(result)
                    self.events.append(self.successes == 0 ? "failure" : "success")
                    self.onCompletion?(result)
                }
            )
        }
    }
}
