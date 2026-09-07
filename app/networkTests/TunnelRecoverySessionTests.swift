import Foundation
import XCTest

final class TunnelRecoverySessionTests: XCTestCase {
    private typealias Session = TunnelRecoverySession<String, String>

    func testAcceptedSessionSnapshotKeepsIntentOwnerAndCallbacksCoherent() throws {
        let session = Session()
        let ticket = session.begin(owner: "current-owner", savedLocationHasCurrentOwner: true)
        let destination = try XCTUnwrap(session.snapshot(ticket: ticket)).destinationTicket
        XCTAssertTrue(session.acceptDestination(destination, present: true, observedIntent: "current-connect"))
        var events: [String] = []
        XCTAssertTrue(session.installCallbacks(
            ticket: ticket,
            restoreDestination: { events.append("restore") },
            reconcileReadiness: { events.append("readiness") }
        ))
        let snapshot = try XCTUnwrap(session.snapshot(ticket: ticket))
        XCTAssertEqual(snapshot.owner, "current-owner")
        XCTAssertEqual(snapshot.observedIntent, "current-connect")
        XCTAssertTrue(snapshot.connectIntended)
        XCTAssertTrue(snapshot.savedLocationHasCurrentOwner)
        try snapshot.restoreDestination?()
        snapshot.reconcileReadiness?()
        XCTAssertEqual(events, ["restore", "readiness"])
    }

    func testCopiedCallbacksCannotRunAfterSessionRetirement() throws {
        let session = Session()
        let ticket = session.begin(owner: "owner", savedLocationHasCurrentOwner: true)
        XCTAssertTrue(session.installCallbacks(
            ticket: ticket,
            restoreDestination: { XCTFail("retired restore") },
            reconcileReadiness: { XCTFail("retired readiness") }
        ))
        let copied = try XCTUnwrap(session.snapshot(ticket: ticket))
        session.retire(ticket)
        XCTAssertThrowsError(try copied.restoreDestination?())
        copied.reconcileReadiness?()
        XCTAssertNil(session.snapshot())
    }

    func testCallbacksAreInvokedOutsideOwnerLock() throws {
        let session = Session()
        let ticket = session.begin(owner: "owner", savedLocationHasCurrentOwner: true)
        var callbacks = 0
        XCTAssertTrue(session.installCallbacks(
            ticket: ticket,
            restoreDestination: {
                XCTAssertNotNil(session.snapshot(ticket: ticket))
                callbacks += 1
            },
            reconcileReadiness: {
                XCTAssertNotNil(session.retire(ticket))
                callbacks += 1
            }
        ))
        let copied = try XCTUnwrap(session.snapshot(ticket: ticket))
        try copied.restoreDestination?()
        copied.reconcileReadiness?()
        XCTAssertEqual(callbacks, 2)
        XCTAssertNil(session.snapshot())
    }

    func testRetiredCallbackCaptureIsReleasedOutsideOwnerLock() {
        let session = Session()
        let ticket = session.begin(owner: "owner", savedLocationHasCurrentOwner: true)
        var released = false
        var capture: ReleaseObservation? = ReleaseObservation {
            XCTAssertNil(session.snapshot())
            released = true
        }
        XCTAssertTrue(session.installCallbacks(
            ticket: ticket,
            restoreDestination: { [capture] in withExtendedLifetime(capture) {} },
            reconcileReadiness: {}
        ))
        capture = nil
        XCTAssertFalse(released)
        session.retire(ticket)
        XCTAssertTrue(released)
    }

    func testRetiredSessionCannotClearOrPublishIntoReplacement() throws {
        let session = Session()
        let old = session.begin(owner: "old-owner", savedLocationHasCurrentOwner: true)
        let oldSnapshot = try XCTUnwrap(session.snapshot(ticket: old))
        let replacement = session.begin(owner: "new-owner", savedLocationHasCurrentOwner: false)
        XCTAssertNil(session.retire(old))
        XCTAssertFalse(session.acceptDestination(oldSnapshot.destinationTicket, present: true, observedIntent: "old-connect"))
        XCTAssertFalse(session.installCallbacks(ticket: old, restoreDestination: {}, reconcileReadiness: {}))
        let current = try XCTUnwrap(session.snapshot(ticket: replacement))
        XCTAssertEqual(current.owner, "new-owner")
        XCTAssertFalse(current.connectIntended)
        XCTAssertNil(current.observedIntent)
        XCTAssertFalse(current.savedLocationHasCurrentOwner)
        XCTAssertFalse(oldSnapshot.readiness === current.readiness)
    }

    func testNewDestinationTicketRejectsOlderQueuedChoice() throws {
        let session = Session()
        let owner = session.begin(owner: "owner", savedLocationHasCurrentOwner: true)
        let old = try XCTUnwrap(session.noteDestinationChange(ticket: owner))
        let current = try XCTUnwrap(session.noteDestinationChange(ticket: owner))
        XCTAssertFalse(session.observeLocation(old, present: true, at: Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(session.savedLocationPersisted(old))
        XCTAssertFalse(session.acceptDestination(old, present: true, observedIntent: "old-connect"))
        XCTAssertTrue(session.observeLocation(current, present: false, at: Date(timeIntervalSince1970: 2)))
        let state = try XCTUnwrap(session.snapshot(ticket: owner))
        XCTAssertFalse(state.connectIntended)
        XCTAssertEqual(state.liveDisconnectAt, Date(timeIntervalSince1970: 2))
    }

    func testFailedSharedReadKeepsLiveDisconnectAndPriorObservedIntent() throws {
        let session = Session()
        let owner = session.begin(owner: "owner", savedLocationHasCurrentOwner: true)
        let initial = try XCTUnwrap(session.snapshot(ticket: owner)).destinationTicket
        XCTAssertTrue(session.acceptDestination(initial, present: true, observedIntent: "old-connect"))
        let disconnect = try XCTUnwrap(session.noteDestinationChange(ticket: owner))
        let now = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(session.observeLocation(disconnect, present: false, at: now))
        XCTAssertThrowsError(try session.observeIntentAfterLiveDisconnect(disconnect) {
            throw NSError(domain: "private-read-marker", code: 7)
        })
        let current = try XCTUnwrap(session.snapshot(ticket: owner))
        XCTAssertFalse(current.connectIntended)
        XCTAssertEqual(current.liveDisconnectAt, now)
        XCTAssertEqual(current.observedIntent, "old-connect")
        XCTAssertFalse(tunnelConnectIntentIsNewer(changedAt: Date(timeIntervalSince1970: 100), liveDisconnectAt: current.liveDisconnectAt))
        XCTAssertTrue(tunnelConnectIntentIsNewer(changedAt: Date(timeIntervalSince1970: 201), liveDisconnectAt: current.liveDisconnectAt))
    }

    func testSharedReadCanRetireSessionWithoutDeadlockOrLatePublication() throws {
        let session = Session()
        let old = session.begin(owner: "old-owner", savedLocationHasCurrentOwner: true)
        let disconnect = try XCTUnwrap(session.noteDestinationChange(ticket: old))
        XCTAssertTrue(session.observeLocation(disconnect, present: false, at: Date(timeIntervalSince1970: 200)))
        var replacement: Session.Ticket?
        XCTAssertFalse(try session.observeIntentAfterLiveDisconnect(disconnect) {
            XCTAssertNotNil(session.retire(old))
            replacement = session.begin(owner: "new-owner", savedLocationHasCurrentOwner: false)
            return "late-old-read"
        })
        let current = try XCTUnwrap(session.snapshot(ticket: try XCTUnwrap(replacement)))
        XCTAssertEqual(current.owner, "new-owner")
        XCTAssertNil(current.observedIntent)
        XCTAssertNil(current.liveDisconnectAt)
    }

    func testLateSettingsCompletionCannotAffectReplacementReadinessOwner() throws {
        let session = Session()
        let old = session.begin(owner: "old", savedLocationHasCurrentOwner: true)
        let oldState = try XCTUnwrap(session.snapshot(ticket: old))
        let oldApply = try XCTUnwrap(oldState.readiness.begin(.init(readiness: .connected, dnsOwned: true)))
        session.retire(old)
        let replacement = session.begin(owner: "new", savedLocationHasCurrentOwner: false)
        let current = try XCTUnwrap(session.snapshot(ticket: replacement))
        XCTAssertEqual(oldState.readiness.complete(oldApply, succeeded: false), .stale)
        XCTAssertEqual(current.readiness.generation, 0)
        XCTAssertNotNil(current.readiness.begin(.init(readiness: .local, dnsOwned: false)))
    }

    func testDiagnosticSnapshotSurvivesRetirementWithoutReadingReplacement() throws {
        let session = Session()
        let old = session.begin(
            owner: "old", savedLocationHasCurrentOwner: true,
            readDiagnostics: {
                XCTAssertNil(session.snapshot())
                return Session.Diagnostics(consumerPresent: true, hasLocation: true, providerCount: 0)
            }
        )
        let retired = try XCTUnwrap(session.retire(old))
        let observed = try XCTUnwrap(retired.readDiagnostics?())
        XCTAssertTrue(observed.consumerPresent)
        XCTAssertTrue(observed.hasLocation)
        XCTAssertEqual(observed.providerCount, 0)
    }

    // Fixed finite parallel work exercises the same production holder under
    // TSan. The invariant is order-independent; no sleeps, polling or network.
    func testConcurrentSnapshotAndRetirementMaintainCoherentOwnerIntent() {
        let session = Session()
        let failuresLock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for iteration in 0..<128 {
                if worker == 0 {
                    _ = session.begin(owner: "owner-\(iteration)", savedLocationHasCurrentOwner: false)
                }
                if let state = session.snapshot() {
                    if iteration.isMultiple(of: 7) {
                        session.retire(state.ticket)
                    } else {
                        _ = session.acceptDestination(state.destinationTicket, present: true, observedIntent: state.owner)
                    }
                }
                if let state = session.snapshot(), state.connectIntended && state.observedIntent != state.owner {
                    failuresLock.lock()
                    failures += 1
                    failuresLock.unlock()
                }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    private final class ReleaseObservation {
        private let released: () -> Void
        init(_ released: @escaping () -> Void) { self.released = released }
        deinit { released() }
    }
}
