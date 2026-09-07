import Foundation
import XCTest

// The production native ordering/ownership boundary, without an app or SDK
// constructor. Real SDK Load/save/consumer replay is covered separately.
final class TunnelPreferenceStartupTests: XCTestCase {
    func testLoadAndAutoSavePrecedeFirstIntentMutationAndRpc() throws {
        var events: [String] = []
        var saving = false
        let loaded: String? = try loadTunnelPreferences(
            intent: .connect, loadOwnedPreferences: true, isCurrent: { true },
            persistDisconnect: { XCTFail("connect is not a disconnect") },
            load: { events.append("load"); return "loaded-default" },
            enableAutoSave: { saving = true; events.append("autosave") }
        )
        let plan = try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: true,
            loadSaved: { nil as String? }, loadDefault: { loaded },
            bestAvailable: { XCTFail("specific default must win"); return "best" },
            isCurrent: { true },
            apply: { plan in
                XCTAssertTrue(saving)
                XCTAssertEqual(plan.location, "loaded-default")
                events.append("checked-mutation")
            }
        )
        try finishTunnelLocalAuthSession(
            configureRpc: { XCTAssertTrue(saving); events.append("rpc") },
            publishedClientJwt: { "accepted-client" }, publishClient: { _ in }
        )
        XCTAssertEqual(plan.stage, .sharedDefault)
        XCTAssertEqual(events, ["load", "autosave", "checked-mutation", "rpc"])
    }

    func testCurrentDisconnectClearsSavedCurrentBeforeLoad() throws {
        var saved: String? = "old-current"
        var events: [String] = []
        let result: Bool? = try loadTunnelPreferences(
            intent: .disconnect, loadOwnedPreferences: true, isCurrent: { true },
            persistDisconnect: { saved = nil; events.append("disconnect") },
            load: { XCTAssertNil(saved); events.append("load"); return true },
            enableAutoSave: { events.append("autosave") }
        )
        XCTAssertEqual(result, true)
        XCTAssertEqual(events, ["disconnect", "load", "autosave"])
    }

    func testInitiallyUnownedAuthSkipsLoadWithoutTouchingOrphanPreferences() throws {
        let orphan = "other-owner-specific-destination"
        var saving = false
        var reports: [String] = []
        let result: String? = try loadTunnelPreferences(
            intent: .none, loadOwnedPreferences: false, isCurrent: { true },
            persistDisconnect: { XCTFail("no current disconnect") },
            load: { XCTFail("new auth does not own orphan preferences"); return orphan },
            enableAutoSave: { saving = true },
            report: { reports.append($0 + "=" + $1) }
        )
        XCTAssertNil(result)
        XCTAssertTrue(saving)
        XCTAssertEqual(orphan, "other-owner-specific-destination")
        XCTAssertEqual(reports, ["preferences-load=skipped-unowned", "auto-save=enabled"])
    }

    func testInitiallyUnownedCurrentDisconnectStillCommitsBeforeEnablingSave() throws {
        var events: [String] = []
        let result: Bool? = try loadTunnelPreferences(
            intent: .disconnect, loadOwnedPreferences: false, isCurrent: { true },
            persistDisconnect: { events.append("disconnect") },
            load: { XCTFail("must not load orphan default"); return true },
            enableAutoSave: { events.append("autosave") }
        )
        XCTAssertNil(result)
        XCTAssertEqual(events, ["disconnect", "autosave"])
    }

    func testRequiredLoadFailureCannotEnableSaveOrReachPublication() {
        var enabled = false
        var returned = false
        do {
            let _: Bool? = try loadTunnelPreferences(
                intent: .connect, loadOwnedPreferences: true, isCurrent: { true },
                persistDisconnect: { XCTFail("not a disconnect") },
                load: { throw FixtureError.read }, enableAutoSave: { enabled = true }
            )
            returned = true
        } catch {}
        XCTAssertFalse(enabled)
        XCTAssertFalse(returned)
    }

    func testFailedAutoSaveEnableCannotReachPublication() {
        var loaded = false
        var returned = false
        do {
            let _: Bool? = try loadTunnelPreferences(
                intent: .none, loadOwnedPreferences: true, isCurrent: { true },
                persistDisconnect: { XCTFail("not a disconnect") },
                load: { loaded = true; return true },
                enableAutoSave: { throw FixtureError.write }
            )
            returned = true
        } catch {}
        XCTAssertTrue(loaded)
        XCTAssertFalse(returned)
    }

    func testRetirementDuringLoadCannotEnableSaveOrPublish() {
        var current = true
        var enabled = false
        XCTAssertThrowsError(try loadTunnelPreferences(
            intent: .none, loadOwnedPreferences: true, isCurrent: { current },
            persistDisconnect: { XCTFail("not a disconnect") },
            load: { current = false; return true }, enableAutoSave: { enabled = true }
        ))
        XCTAssertFalse(enabled)
    }

    func testNewIntentAfterDisconnectCommitPreventsOldLoad() {
        var current = true
        var loaded = false
        XCTAssertThrowsError(try loadTunnelPreferences(
            intent: .disconnect, loadOwnedPreferences: true, isCurrent: { current },
            persistDisconnect: { current = false },
            load: { loaded = true; return true },
            enableAutoSave: { XCTFail("superseded startup") }
        ))
        XCTAssertFalse(loaded)
    }

    func testFailedIntentObservationDoesNotBecomeAbsentIntent() {
        var loaded = false
        XCTAssertThrowsError(try loadTunnelPreferences(
            intent: .none, loadOwnedPreferences: true, isCurrent: { throw FixtureError.read },
            persistDisconnect: { XCTFail("unavailable intent") },
            load: { loaded = true; return true }, enableAutoSave: { XCTFail("unavailable intent") }
        ))
        XCTAssertFalse(loaded)
    }

    func testPrivateLoadErrorProducesOnlyFixedBreadcrumbs() {
        var reports: [String] = []
        XCTAssertThrowsError(try loadTunnelPreferences(
            intent: .connect, loadOwnedPreferences: true, isCurrent: { true },
            persistDisconnect: { XCTFail("not a disconnect") },
            load: { () throws -> Bool in
                throw NSError(domain: "private-marker", code: 91, userInfo: [NSLocalizedDescriptionKey: "/private-marker/token"])
            },
            enableAutoSave: { XCTFail("load failed") },
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertEqual(reports, ["preferences-load=started", "preferences-load=failed"])
        XCTAssertFalse(reports.joined().contains("private-marker"))
    }

    func testRetiredDefaultSaveCannotClearReplacementLoadFailure() throws {
        let holder = TunnelRecoverySession<String, String>()
        let old = holder.begin(owner: "old", savedLocationHasCurrentOwner: true)
        XCTAssertTrue(holder.observeDefaultPreference(old, unavailable: true))
        let current = holder.begin(owner: "current", savedLocationHasCurrentOwner: true)
        XCTAssertTrue(holder.observeDefaultPreference(current, unavailable: true))
        XCTAssertFalse(holder.observeDefaultPreference(old, unavailable: false))
        XCTAssertTrue(try XCTUnwrap(holder.snapshot(ticket: current)).defaultPreferenceUnavailable)
        XCTAssertTrue(holder.observeDefaultPreference(current, unavailable: false))
        XCTAssertFalse(try XCTUnwrap(holder.snapshot(ticket: current)).defaultPreferenceUnavailable)
    }

    func testUncommittedChoiceCannotOwnOrphanSavedPreferences() throws {
        let holder = TunnelRecoverySession<String, String>()
        let ticket = holder.begin(owner: "current", savedLocationHasCurrentOwner: false)
        let destination = try XCTUnwrap(holder.snapshot(ticket: ticket)).destinationTicket
        XCTAssertTrue(holder.acceptDestination(
            destination, present: true, observedIntent: "new-connect", savedLocationIsVerified: false
        ))
        XCTAssertFalse(try XCTUnwrap(holder.snapshot(ticket: ticket)).savedLocationHasCurrentOwner)
        XCTAssertTrue(holder.savedLocationPersisted(destination))
        XCTAssertTrue(try XCTUnwrap(holder.snapshot(ticket: ticket)).savedLocationHasCurrentOwner)
    }

    func testCheckedMutationCallbackCanAdvanceDestinationTicketAfterIntentAdmission() throws {
        let holder = TunnelRecoverySession<String, String>()
        let ticket = holder.begin(owner: "current", savedLocationHasCurrentOwner: false)
        let destination = try XCTUnwrap(holder.snapshot(ticket: ticket)).destinationTicket
        let plan = try restoreTunnelDestination(
            intent: .connect, savedLocationHasCurrentOwner: false,
            loadSaved: { nil as String? }, loadDefault: { nil },
            bestAvailable: { "new-choice" }, isCurrent: { holder.isCurrent(destination) },
            apply: { plan in
                XCTAssertTrue(holder.acceptDestination(
                    destination, present: true, observedIntent: "current-connect", savedLocationIsVerified: false
                ))
                // SDK mutation notifications may run synchronously before its
                // checked method returns. There is no second native persistence
                // step that mistakes that owned callback for stale application.
                let changed = try XCTUnwrap(holder.noteDestinationChange(ticket: ticket))
                XCTAssertTrue(holder.observeLocation(changed, present: plan.location != nil, at: Date(timeIntervalSince1970: 1)))
                XCTAssertTrue(holder.savedLocationPersisted(changed))
            }
        )
        XCTAssertEqual(plan.stage, .sharedBestAvailable)
        let current = try XCTUnwrap(holder.snapshot(ticket: ticket))
        XCTAssertEqual(current.observedIntent, "current-connect")
        XCTAssertTrue(current.connectIntended)
        XCTAssertTrue(current.savedLocationHasCurrentOwner)
        XCTAssertFalse(holder.isCurrent(destination))
    }

    func testSavedPreferenceThenApplyFailureReportsCommitSeparately() {
        var reports: [String] = []
        XCTAssertFalse(reportTunnelPreferenceSave(
            preference: "connect-location", autoSaveEnabled: true, saved: true, hasError: true,
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertEqual(reports, ["destination-persist=completed", "destination-apply=failed"])
    }

    func testFailedEnabledSaveDoesNotClaimLiveApplication() {
        var reports: [String] = []
        XCTAssertFalse(reportTunnelPreferenceSave(
            preference: "default-location", autoSaveEnabled: true, saved: false, hasError: true,
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertEqual(reports, ["default-persist=failed"])
    }

    func testDisabledAutoSaveIsNotReportedAsAnIoFailure() {
        var reports: [String] = []
        XCTAssertFalse(reportTunnelPreferenceSave(
            preference: "connect-location", autoSaveEnabled: false, saved: false, hasError: false,
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertEqual(reports, ["auto-save=disabled"])
    }

    func testSuccessfulDefaultSaveReportsItsOwnOperationStages() {
        var reports: [String] = []
        XCTAssertTrue(reportTunnelPreferenceSave(
            preference: "default-location", autoSaveEnabled: true, saved: true, hasError: false,
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertEqual(reports, ["default-persist=completed", "default-apply=applied"])
    }

    func testUnknownPreferenceCannotLeakIntoRecoveryStage() {
        var reports: [String] = []
        XCTAssertFalse(reportTunnelPreferenceSave(
            preference: "private-marker/credential", autoSaveEnabled: true, saved: false, hasError: true,
            report: { reports.append($0 + "=" + $1) }
        ))
        XCTAssertTrue(reports.isEmpty)
    }

    private enum FixtureError: Error { case read, write }
}
