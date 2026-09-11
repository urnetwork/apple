import Foundation
import XCTest
@testable import URnetwork

// The exact reservation/publication/take boundary used by PacketTunnelProvider.
// Cleanup uses its real production once-owner; SDK work is represented only by
// held constructor completion here, not a claim of a whole NE lifecycle test.
final class TunnelProviderSessionOwnerTests: XCTestCase {
    func testAlreadyRunningStartupPreservesPendingRecoveryWork() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let closed = Counter()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "running", cleanup: TunnelStartupCleanup { closed.increment() }), ticket: ticket))
        let transportWork = DispatchWorkItem {}
        let wakeWork = DispatchWorkItem {}
        var queued: [() -> Void] = []
        var cancellations = 0
        let admission = owner.beginStartup(isAlreadyRunning: { existing in
            // The production predicate reads SDK state outside the owner lock.
            XCTAssertEqual(owner.snapshot()?.value.name, existing.name)
            return true
        }, prepareWithLock: {
            XCTFail("an already-running start prepared replacement bookkeeping")
        }, enqueue: { queued.append($0) }, cancelRecovery: {
            cancellations += 1
            transportWork.cancel()
            wakeWork.cancel()
        })
        guard case .alreadyRunning = admission else { XCTFail("duplicate startup was not reused"); return }
        XCTAssertTrue(queued.isEmpty)
        for action in queued { action() }
        XCTAssertEqual(cancellations, 0)
        XCTAssertFalse(transportWork.isCancelled)
        XCTAssertFalse(wakeWork.isCancelled)
        XCTAssertTrue(owner.isCurrent(ticket))
        XCTAssertEqual(owner.snapshot()?.value.name, "running")
        XCTAssertEqual(closed.value, 0)
    }

    func testReservedUnpublishedStartupCancelsRecoveryOutsideOwnerLock() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (old, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "old", cleanup: TunnelStartupCleanup {}), ticket: old))
        let transportWork = DispatchWorkItem {}
        let wakeWork = DispatchWorkItem {}
        var queued: [() -> Void] = []
        var events: [String] = []
        let admission = owner.beginStartup(isAlreadyRunning: { existing in
            XCTAssertEqual(owner.snapshot()?.value.name, existing.name)
            events.append("predicate")
            return false
        }, prepareWithLock: {
            events.append("prepare")
        }, enqueue: { action in
            // Reentry proves enqueue is after reservation and outside its lock.
            XCTAssertNil(owner.snapshot())
            events.append("enqueue")
            queued.append(action)
        }, cancelRecovery: {
            XCTAssertNil(owner.snapshot())
            events.append("cancel")
            transportWork.cancel()
            wakeWork.cancel()
        })
        guard case .reserved(let ticket, let previous) = admission else { XCTFail("startup was not reserved"); return }
        XCTAssertEqual(previous?.name, "old")
        XCTAssertTrue(owner.isCurrent(ticket))
        XCTAssertNil(owner.snapshot(ticket: ticket))
        XCTAssertEqual(events, ["predicate", "prepare", "enqueue"])
        XCTAssertEqual(queued.count, 1)
        XCTAssertFalse(transportWork.isCancelled)
        XCTAssertFalse(wakeWork.isCancelled)
        for action in queued { action() }
        XCTAssertEqual(events, ["predicate", "prepare", "enqueue", "cancel"])
        XCTAssertTrue(transportWork.isCancelled)
        XCTAssertTrue(wakeWork.isCancelled)
        XCTAssertTrue(owner.isCurrent(ticket))
    }

    func testPublishedStartupStillCancelsItsReservedRecoveryWork() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let transportWork = DispatchWorkItem {}
        let wakeWork = DispatchWorkItem {}
        var queued: [() -> Void] = []
        var cancellations = 0
        let admission = owner.beginStartup(isAlreadyRunning: { _ in
            XCTFail("an empty owner has no duplicate candidate")
            return false
        }, enqueue: { action in
            XCTAssertNil(owner.snapshot())
            queued.append(action)
        }, cancelRecovery: {
            XCTAssertEqual(owner.snapshot()?.value.name, "published")
            cancellations += 1
            transportWork.cancel()
            wakeWork.cancel()
        })
        guard case .reserved(let ticket, let previous) = admission else { XCTFail("startup was not reserved"); return }
        XCTAssertNil(previous)
        XCTAssertTrue(owner.publish(Session(name: "published", cleanup: TunnelStartupCleanup {}), ticket: ticket))
        XCTAssertEqual(queued.count, 1)
        XCTAssertFalse(transportWork.isCancelled)
        XCTAssertFalse(wakeWork.isCancelled)
        for action in queued { action() }
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(transportWork.isCancelled)
        XCTAssertTrue(wakeWork.isCancelled)
        XCTAssertTrue(owner.isCurrent(ticket))
    }

    func testNewerStartupTicketRejectsOldQueuedRecoveryCancellation() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        var transportWork = DispatchWorkItem {}
        var wakeWork = DispatchWorkItem {}
        var queued: [() -> Void] = []
        var cancellations = 0
        let admission = owner.beginStartup(isAlreadyRunning: { _ in false }, enqueue: {
            queued.append($0)
        }, cancelRecovery: {
            cancellations += 1
            transportWork.cancel()
            wakeWork.cancel()
        })
        guard case .reserved(let old, _) = admission else { XCTFail("old startup was not reserved"); return }
        let (current, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "replacement", cleanup: TunnelStartupCleanup {}), ticket: current))
        // Match provider fields: the old queued closure would reach these new
        // work items, not just cancel objects retained from its original start.
        transportWork = DispatchWorkItem {}
        wakeWork = DispatchWorkItem {}
        XCTAssertFalse(owner.isCurrent(old))
        XCTAssertEqual(queued.count, 1)
        for action in queued { action() }
        XCTAssertEqual(cancellations, 0)
        XCTAssertFalse(transportWork.isCancelled)
        XCTAssertFalse(wakeWork.isCancelled)
        XCTAssertTrue(owner.isCurrent(current))
        XCTAssertEqual(owner.snapshot()?.value.name, "replacement")
    }

    func testStoppedStartupRejectsQueuedRecoveryCancellation() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let transportWork = DispatchWorkItem {}
        let wakeWork = DispatchWorkItem {}
        var queued: [() -> Void] = []
        var cancellations = 0
        let admission = owner.beginStartup(isAlreadyRunning: { _ in false }, enqueue: {
            queued.append($0)
        }, cancelRecovery: {
            cancellations += 1
            transportWork.cancel()
            wakeWork.cancel()
        })
        guard case .reserved(let ticket, _) = admission else { XCTFail("startup was not reserved"); return }
        XCTAssertNil(owner.take(ticket), "stop must retire even an unpublished reservation")
        XCTAssertFalse(owner.isCurrent(ticket))
        XCTAssertEqual(queued.count, 1)
        for action in queued { action() }
        XCTAssertEqual(cancellations, 0)
        XCTAssertFalse(transportWork.isCancelled)
        XCTAssertFalse(wakeWork.isCancelled)
        XCTAssertNil(owner.snapshot())
    }

    func testLogoutRejectedStartupDoesNotQueueRecoveryCancellation() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "retiring", cleanup: TunnelStartupCleanup {}), ticket: ticket))
        let (logout, retiring) = owner.beginLogout()
        defer { owner.finishLogout(logout) }
        XCTAssertEqual(retiring?.name, "retiring")
        let transportWork = DispatchWorkItem {}
        let wakeWork = DispatchWorkItem {}
        var queued: [() -> Void] = []
        var cancellations = 0
        let admission = owner.beginStartup(isAlreadyRunning: { _ in
            XCTFail("logout already retired the previous provider")
            return false
        }, prepareWithLock: {
            XCTFail("logout-rejected startup prepared replacement bookkeeping")
        }, enqueue: { queued.append($0) }, cancelRecovery: {
            cancellations += 1
            transportWork.cancel()
            wakeWork.cancel()
        })
        guard case .unavailable = admission else { XCTFail("logout admitted a startup"); return }
        XCTAssertTrue(queued.isEmpty)
        for action in queued { action() }
        XCTAssertEqual(cancellations, 0)
        XCTAssertFalse(transportWork.isCancelled)
        XCTAssertFalse(wakeWork.isCancelled)
        XCTAssertNil(owner.snapshot())
    }

    func testHeldOldStartupCannotPublishOverNewerLiveSession() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let oldClosed = Counter()
        let newClosed = Counter()
        let (oldTicket, _) = try XCTUnwrap(owner.begin())
        let old = Session(name: "old", cleanup: TunnelStartupCleanup { oldClosed.increment() })
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { XCTFail("held constructor release"); done.signal(); return }
            if !owner.publish(old, ticket: oldTicket) { old.cleanup.cleanUpNow() }
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let (newTicket, retired) = try XCTUnwrap(owner.begin())
        XCTAssertNil(retired)
        let current = Session(name: "new", cleanup: TunnelStartupCleanup { newClosed.increment() })
        XCTAssertTrue(owner.publish(current, ticket: newTicket))
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try XCTUnwrap(owner.snapshot()).value.name, "new")
        XCTAssertEqual(oldClosed.value, 1)
        XCTAssertEqual(newClosed.value, 0)
        owner.take(newTicket)?.cleanup.cleanUpNow()
        XCTAssertEqual(newClosed.value, 1)
    }

    func testStopRetiresEmptyReservationBeforeHeldStartupCanPublish() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let closed = Counter()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        let old = Session(name: "old", cleanup: TunnelStartupCleanup { closed.increment() })
        XCTAssertNil(owner.take())
        XCTAssertFalse(owner.isCurrent(ticket))
        XCTAssertFalse(owner.publish(old, ticket: ticket))
        old.cleanup.cleanUpNow()
        XCTAssertNil(owner.snapshot())
        XCTAssertEqual(closed.value, 1)
    }

    func testLateOldFailureCannotTakeOrClearNewSessionReferences() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (old, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "old", cleanup: TunnelStartupCleanup {}), ticket: old))
        let (current, retired) = try XCTUnwrap(owner.begin())
        retired?.cleanup.cleanUpNow()
        XCTAssertTrue(owner.publish(Session(name: "current", cleanup: TunnelStartupCleanup {}), ticket: current))
        XCTAssertNil(owner.take(old))
        XCTAssertFalse(owner.update(old) { $0.name = "obsolete configuration" })
        XCTAssertEqual(try XCTUnwrap(owner.snapshot()).value.name, "current")
        XCTAssertTrue(owner.isCurrent(current))
    }

    func testSessionReferenceUpdateAndTakeUseOneOwnerTicket() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "initial", cleanup: TunnelStartupCleanup {}), ticket: ticket))
        XCTAssertTrue(owner.update(ticket) { $0.name = "published" })
        XCTAssertEqual(try XCTUnwrap(owner.take(ticket)).name, "published")
        XCTAssertFalse(owner.update(ticket) { $0.name = "late" })
        XCTAssertFalse(owner.publish(Session(name: "late", cleanup: TunnelStartupCleanup {}), ticket: ticket))
        XCTAssertNil(owner.snapshot())
    }

    func testTakenCleanupCanReenterReservationOutsideOwnerLock() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        var replacement: TunnelProviderSessionOwner<Session>.Ticket?
        let cleanup = TunnelStartupCleanup { replacement = owner.begin()?.0 }
        XCTAssertTrue(owner.publish(Session(name: "old", cleanup: cleanup), ticket: ticket))
        owner.take(ticket)?.cleanup.cleanUpNow()
        XCTAssertTrue(owner.isCurrent(try XCTUnwrap(replacement)))
        XCTAssertFalse(owner.isCurrent(ticket))
    }

    func testConcurrentTakeDeliversExactlyOneSessionCleanup() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let closed = Counter()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "live", cleanup: TunnelStartupCleanup { closed.increment() }), ticket: ticket))
        let group = DispatchGroup()
        for _ in 0..<24 {
            group.enter()
            DispatchQueue.global().async {
                owner.take(ticket)?.cleanup.cleanUpNow()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(closed.value, 1)
        XCTAssertNil(owner.snapshot())
    }

    // Hold exactly after publication returns, not before constructor return.
    // The real packet/recovery begin operations must already be admitted; the
    // old caller's later retirement delivery cannot reset the newer generation.
    func testHeldOldPublicationCannotBeginBookkeepingAfterNewerStart() throws {
        let sessions = ComposedSessions()
        let oldTicket = try sessions.reserve()
        let published = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard let old = sessions.publish("old", ticket: oldTicket) else {
                XCTFail("old publication"); published.signal(); done.signal(); return
            }
            published.signal()
            guard resume.wait(timeout: .now() + 5) == .success else {
                XCTFail("old publication release"); done.signal(); return
            }
            sessions.recovery.completeRetirement(old.previousRecovery)
            XCTAssertFalse(sessions.packets.isActive(generation: old.packet))
            XCTAssertFalse(sessions.recovery.isCurrent(old.recovery))
            done.signal()
        }
        XCTAssertEqual(published.wait(timeout: .now() + 5), .success)
        let currentTicket = try sessions.reserve()
        let current = try XCTUnwrap(sessions.publish("current", ticket: currentTicket))
        resume.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try XCTUnwrap(sessions.owner.snapshot()).value.name, "current")
        XCTAssertTrue(sessions.packets.isActive(generation: current.packet))
        XCTAssertTrue(sessions.recovery.isCurrent(current.recovery))
        XCTAssertEqual(try XCTUnwrap(sessions.recovery.snapshot()).owner, "current")
    }

    func testRejectedOldPublicationDoesNotRunAnyBookkeepingPreparation() throws {
        let sessions = ComposedSessions()
        let old = try sessions.reserve()
        let currentTicket = try sessions.reserve()
        let current = try XCTUnwrap(sessions.publish("current", ticket: currentTicket))
        XCTAssertNil(sessions.publish("old", ticket: old))
        XCTAssertTrue(sessions.packets.isActive(generation: current.packet))
        XCTAssertTrue(sessions.recovery.isCurrent(current.recovery))
    }

    func testLateOldStopCannotRetireNewBookkeeping() throws {
        let sessions = ComposedSessions()
        let oldTicket = try sessions.reserve()
        let old = try XCTUnwrap(sessions.publish("old", ticket: oldTicket))
        let currentTicket = try sessions.reserve()
        let current = try XCTUnwrap(sessions.publish("current", ticket: currentTicket))
        sessions.stop(oldTicket)
        XCTAssertTrue(sessions.packets.isActive(generation: current.packet))
        XCTAssertTrue(sessions.recovery.isCurrent(current.recovery))
        XCTAssertFalse(sessions.packets.isActive(generation: old.packet))
        sessions.stop(currentTicket)
        XCTAssertFalse(sessions.packets.isActive(generation: current.packet))
        XCTAssertNil(sessions.recovery.snapshot())
        XCTAssertNil(sessions.owner.snapshot())
    }

    func testPreparedRecoveryCancellationCanReenterProviderAfterUnlock() throws {
        let sessions = ComposedSessions()
        let ticket = try sessions.reserve()
        let current = try XCTUnwrap(sessions.publish("current", ticket: ticket))
        let cancelled = Counter()
        let startup = TunnelAuthStartupContinuation(
            enqueue: { $0() }, subscribe: { _, _ in
                return {
                    // This would deadlock if prepareRetire delivered cancellation
                    // while the composing provider lock was still held.
                    _ = sessions.owner.snapshot()
                    cancelled.increment()
                }
            }, scheduleDeadline: { _ in {} }, isCurrent: { true },
            observe: { throw NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "auth snapshot was superseded or is not settled"
            ]) }, completion: { _ in }
        )
        XCTAssertTrue(sessions.recovery.installAuthStartup(startup, ticket: current.recovery))
        startup.start()
        sessions.stop(ticket)
        XCTAssertEqual(cancelled.value, 1)
    }

    func testDelayedOldRetirementDeliveryCannotInvalidateNewReadiness() throws {
        let sessions = ComposedSessions()
        let oldTicket = try sessions.reserve()
        _ = try XCTUnwrap(sessions.publish("old", ticket: oldTicket))
        var retired: ComposedSessions.Recovery.Snapshot?
        let (currentTicket, previous) = try XCTUnwrap(sessions.owner.begin {
            sessions.packets.stop()
            retired = sessions.recovery.prepareRetire()
        })
        previous?.cleanup.cleanUpNow()
        let current = try XCTUnwrap(sessions.publish("current", ticket: currentTicket))
        let state = try XCTUnwrap(sessions.recovery.snapshot(ticket: current.recovery))
        let readiness = try XCTUnwrap(state.readiness.begin(.init(readiness: .connected, dnsOwned: true)))
        sessions.recovery.completeRetirement(retired)
        XCTAssertEqual(state.readiness.complete(readiness, succeeded: true), .applied)
        XCTAssertTrue(sessions.packets.isActive(generation: current.packet))
    }

    func testExplicitLogoutWithoutPublishedProviderStillClearsSharedIntent() throws {
        let sessions = ComposedSessions()
        let pending = try sessions.reserve()
        let suite = "network.ur.tests.explicit-logout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        TunnelIntentStore.record(connect: true, source: TunnelIntentStore.sourceApp, in: defaults)
        var sharedHistoryCleared = false
        var retired: ComposedSessions.Recovery.Snapshot?
        sessions.owner.withLogout(prepareWithLock: {
            sessions.packets.stop()
            retired = sessions.recovery.prepareRetire()
        }, clear: { provider in
            sessions.recovery.completeRetirement(retired)
            XCTAssertNil(provider)
            XCTAssertNil(sessions.owner.begin(), "start cannot overtake explicit logout clears")
            TunnelIntentStore.record(connect: false, source: TunnelIntentStore.sourceApp, in: defaults)
            sharedHistoryCleared = true
        })
        XCTAssertTrue(sharedHistoryCleared)
        XCTAssertFalse(try XCTUnwrap(TunnelIntentStore.loadChecked(from: defaults)).connect)
        XCTAssertFalse(sessions.owner.isCurrent(pending))
        XCTAssertNotNil(sessions.owner.begin())
    }

    func testExplicitLogoutRejectsHeldOldConstructorPublication() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let prepared = Counter()
        DispatchQueue.global().async {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                XCTFail("held constructor release"); done.signal(); return
            }
            XCTAssertFalse(owner.publish(
                Session(name: "old", cleanup: TunnelStartupCleanup {}), ticket: ticket,
                prepareWithLock: { prepared.increment() }
            ))
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        owner.withLogout { provider in XCTAssertNil(provider) }
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(prepared.value, 0)
        XCTAssertNil(owner.snapshot())
        // This rejects native publication; it does not assert that an SDK
        // constructor already admitted elsewhere cannot have written auth.
    }

    func testOverlappingExplicitLogoutsKeepStartupClosedUntilBothComplete() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (first, _) = owner.beginLogout()
        let (second, _) = owner.beginLogout()
        XCTAssertNotEqual(first, second)
        XCTAssertNil(owner.begin())
        XCTAssertTrue(owner.finishLogout(first))
        XCTAssertFalse(owner.finishLogout(first))
        XCTAssertNil(owner.begin(), "first reply cannot reopen admission under second clear")
        XCTAssertTrue(owner.finishLogout(second))
        XCTAssertNotNil(owner.begin())
    }

    func testLogoutCleanupCanReenterOwnerWithoutAdmittingNewStart() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        let closed = Counter()
        XCTAssertTrue(owner.publish(Session(name: "current", cleanup: TunnelStartupCleanup {
            XCTAssertNil(owner.begin())
            XCTAssertNil(owner.snapshot())
            closed.increment()
        }), ticket: ticket))
        owner.withLogout { provider in
            XCTAssertEqual(provider?.name, "current")
            provider?.cleanup.cleanUpNow()
        }
        XCTAssertEqual(closed.value, 1)
        XCTAssertNotNil(owner.begin(), "reply follows completed clear/cleanup")
    }

    func testLateOldTicketedRetirementCannotClearPostLogoutSession() throws {
        let sessions = ComposedSessions()
        let old = try sessions.reserve()
        _ = try XCTUnwrap(sessions.publish("old", ticket: old))
        var retiring: ComposedSessions.Recovery.Snapshot?
        sessions.owner.withLogout(prepareWithLock: {
            sessions.packets.stop()
            retiring = sessions.recovery.prepareRetire()
        }, clear: { provider in
            sessions.recovery.completeRetirement(retiring)
            provider?.cleanup.cleanUpNow()
        })
        let next = try sessions.reserve()
        let current = try XCTUnwrap(sessions.publish("new", ticket: next))
        sessions.stop(old)
        XCTAssertTrue(sessions.owner.isCurrent(next))
        XCTAssertTrue(sessions.packets.isActive(generation: current.packet))
        XCTAssertTrue(sessions.recovery.isCurrent(current.recovery))
    }

    func testFailedLocalLogoutStillReleasesOnlyItsCompletedAdmission() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        var sharedCleared = false
        XCTAssertThrowsError(try owner.withLogout { _ in
            sharedCleared = true
            throw NSError(domain: "private-marker", code: 7)
        })
        XCTAssertTrue(sharedCleared)
        XCTAssertNotNil(owner.begin())
    }

    func testHeldOldSettingsPlanCannotEnterNewProviderQueue() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (old, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "old-device-plan", cleanup: TunnelStartupCleanup {}), ticket: old))
        let origin = try XCTUnwrap(owner.snapshot(ticket: old))
        let prepared = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let queued = Values()
        DispatchQueue.global().async {
            // As in production, device reads/plan construction precede the
            // native admission lock. Hold between construction and enqueue.
            let plan = origin.value.name
            prepared.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                XCTFail("prepared plan release"); done.signal(); return
            }
            XCTAssertFalse(owner.admitPrepared(origin.ticket) { queued.append(plan) })
            done.signal()
        }
        XCTAssertEqual(prepared.wait(timeout: .now() + 5), .success)
        let (current, previous) = try XCTUnwrap(owner.begin())
        previous?.cleanup.cleanUpNow()
        XCTAssertTrue(owner.publish(Session(name: "current-device-plan", cleanup: TunnelStartupCleanup {}), ticket: current))
        XCTAssertTrue(owner.admitPrepared(current) { queued.append("current-device-plan") })
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(queued.values, ["current-device-plan"])
    }

    func testCurrentSettingsPlanAdmissionDoesNotExecuteDetachedCompletionUnderLock() throws {
        let owner = TunnelProviderSessionOwner<Session>()
        let (ticket, _) = try XCTUnwrap(owner.begin())
        XCTAssertTrue(owner.publish(Session(name: "current", cleanup: TunnelStartupCleanup {}), ticket: ticket))
        var completion: (() -> Void)?
        XCTAssertTrue(owner.admitPrepared(ticket) {
            // Production only detaches/enqueues here; it delivers afterward.
            completion = { XCTAssertNotNil(owner.snapshot(ticket: ticket)) }
        })
        try XCTUnwrap(completion)()
        owner.take(ticket)?.cleanup.cleanUpNow()
        XCTAssertFalse(owner.admitPrepared(ticket) { XCTFail("retired enqueue") })
    }

    func testAdmittedOldPacketKeepsItsCapturedDeviceAfterReplacement() throws {
        let sessions = ComposedSessions()
        let oldTicket = try sessions.reserve()
        let old = try XCTUnwrap(sessions.publish("old-device", ticket: oldTicket))
        let oldDevice = try XCTUnwrap(sessions.owner.snapshot(ticket: oldTicket)).value
        let origin = TunnelPacketReadOrigin(device: oldDevice, generation: old.packet)
        let admitted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let delivered = Values()
        DispatchQueue.global().async {
            XCTAssertTrue(origin.withActiveDevice(sessions.packets) { device in
                admitted.signal()
                guard release.wait(timeout: .now() + 5) == .success else { XCTFail("old packet release"); return }
                delivered.append(device.name)
            })
            done.signal()
        }
        XCTAssertEqual(admitted.wait(timeout: .now() + 5), .success)
        let currentTicket = try sessions.reserve()
        _ = try XCTUnwrap(sessions.publish("new-device", ticket: currentTicket))
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(delivered.values, ["old-device"], "admitted old work must never select a newer device")
        XCTAssertEqual(try XCTUnwrap(sessions.owner.snapshot()).value.name, "new-device")
    }

    func testRetiredPacketOriginIsRejectedWhileCurrentOriginStillDelivers() {
        let packets = TunnelPacketReadOwner()
        let old = TunnelPacketReadOrigin(device: "old", generation: packets.begin())
        packets.stop()
        let current = TunnelPacketReadOrigin(device: "current", generation: packets.begin())
        var received: [String] = []
        XCTAssertFalse(old.withActiveDevice(packets) { received.append($0) })
        XCTAssertTrue(current.withActiveDevice(packets) { received.append($0) })
        XCTAssertEqual(received, ["current"])
    }

    func testReturnPacketAdmissionRejectsRetiredSdkCallbackBeforeDecodeAndInjection() {
        let packets = TunnelPacketReadOwner()
        let old = TunnelPacketReadOrigin(device: "old-sdk", generation: packets.begin())
        packets.stop()
        let current = TunnelPacketReadOrigin(device: "current-sdk", generation: packets.begin())
        let packet = Data([0x45, 0, 0, 0])
        let batch = Data([0, 4]) + packet
        var decodes = 0
        var injected: [Data] = []
        let receive = { (_: String) in
            decodes += 1
            XCTAssertTrue(TunnelPacketBatchCodec.decode(batch) { bytes, _ in injected.append(bytes) })
        }
        XCTAssertFalse(old.withActiveDevice(packets, deliver: receive))
        XCTAssertEqual(decodes, 0)
        XCTAssertTrue(injected.isEmpty)
        XCTAssertTrue(current.withActiveDevice(packets, deliver: receive))
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(injected, [packet])
    }

    // These are the production admission owner and packet/recovery helpers,
    // composed with the same prepare/deliver order as the provider. This is
    // not a substitute for NE settings transactions or a fresh native build.
    private final class ComposedSessions {
        typealias Recovery = TunnelRecoverySession<String, String>
        let owner = TunnelProviderSessionOwner<Session>()
        let packets = TunnelPacketReadOwner()
        let recovery = Recovery()

        struct Publication {
            let packet: UInt64
            let recovery: Recovery.Ticket
            let previousRecovery: Recovery.Snapshot?
        }

        func reserve() throws -> TunnelProviderSessionOwner<Session>.Ticket {
            var retired: Recovery.Snapshot?
            let (ticket, previous) = try XCTUnwrap(owner.begin {
                packets.stop()
                retired = recovery.prepareRetire()
            })
            recovery.completeRetirement(retired)
            previous?.cleanup.cleanUpNow()
            return ticket
        }

        func publish(_ name: String, ticket: TunnelProviderSessionOwner<Session>.Ticket) -> Publication? {
            var publication: Publication?
            guard owner.publish(Session(name: name, cleanup: TunnelStartupCleanup {}), ticket: ticket, prepareWithLock: {
                let packet = self.packets.begin()
                let (recovery, previous) = self.recovery.prepareBegin(owner: name, savedLocationHasCurrentOwner: true)
                publication = Publication(packet: packet, recovery: recovery, previousRecovery: previous)
            }) else { return nil }
            return publication
        }

        func stop(_ ticket: TunnelProviderSessionOwner<Session>.Ticket) {
            var retired: Recovery.Snapshot?
            let previous = owner.take(ticket, prepareWithLock: {
                self.packets.stop()
                retired = self.recovery.prepareRetire()
            })
            recovery.completeRetirement(retired)
            previous?.cleanup.cleanUpNow()
        }
    }

    private struct Session {
        var name: String
        let cleanup: TunnelStartupCleanup
    }

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    private final class Values {
        private let lock = NSLock()
        private var stored: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    }
}
