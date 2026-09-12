import Foundation
// This bundle already loads the app's binding through `@testable import
// URnetwork`; importing the reduced extension binding beside it makes clang
// reject the two differing definitions of every Sdk class. Prefer the app's
// binding and fall back to the extension's only where it is the one present.
#if canImport(URnetworkSdk)
import URnetworkSdk
#elseif canImport(URnetworkExtensionSdk)
import URnetworkExtensionSdk
#endif
import XCTest
@testable import URnetwork

// Actual SDK storage, auth publication, DeviceLocal and consumer construction.
// No app object, DeviceRemote, RPC listener, NetworkExtension or profile is
// created. The whole production helper files must be compiled unchanged.
final class TunnelNativeColdRestoreTests: XCTestCase {
    // Exercise the actual Swift-imported add(_:) overload, not the obsolete
    // Objective-C spelling. SDK persistence must also survive unsubscription.
    func testNativeSaveListenerReportsCommittedPreferenceAndCloses() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let started = try fixture.start(store, intent: nil)
            XCTAssertEqual(started.stage, .localOnly)
            let observer = SaveObserver()
            let subscription = try XCTUnwrap(started.device.add(observer))
            defer { subscription.close() }
            XCTAssertTrue(observer.snapshot().isEmpty, "registration must not replay a preference")

            let first = try fixture.location("observed-default")
            try started.device.setDefaultLocationChecked(first)
            let observed = observer.snapshot()
            XCTAssertEqual(observed.count, 1)
            let result = try XCTUnwrap(observed.first)
            XCTAssertEqual(result.getPreference(), "default-location")
            XCTAssertTrue(result.getAutoSaveEnabled())
            XCTAssertTrue(result.getSaved())
            XCTAssertTrue(result.getError().isEmpty)
            XCTAssertEqual(result.getSequence(), started.device.getLastStateSaveResult()?.getSequence())
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(first))

            subscription.close()
            let second = try fixture.location("saved-without-observer")
            try started.device.setDefaultLocationChecked(second)
            XCTAssertEqual(observer.snapshot().count, 1, "closed subscription received another result")
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(second))
            XCTAssertTrue(try XCTUnwrap(started.device.getDefaultLocation()).equals(second))
            XCTAssertGreaterThan(try XCTUnwrap(started.device.getLastStateSaveResult()).getSequence(), result.getSequence())
            XCTAssertFalse(started.device.getConnectEnabled())
        }
    }

    func testNativeSaveListenerReportsStorageFailureWithoutChangingLivePreference() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let started = try fixture.start(store, intent: nil)
            let accepted = try fixture.location("accepted-default")
            try started.device.setDefaultLocationChecked(accepted)
            let observer = SaveObserver()
            let subscription = try XCTUnwrap(started.device.add(observer))
            defer { subscription.close() }
            XCTAssertTrue(observer.snapshot().isEmpty, "registration must not replay the earlier save")

            let path = try fixture.recordPath(store, name: ".default_location")
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            let rejected = try fixture.location("rejected-default")
            XCTAssertThrowsError(try started.device.setDefaultLocationChecked(rejected)) { error in
                XCTAssertEqual((error as NSError).localizedDescription, "save default-location")
            }
            let observed = observer.snapshot()
            XCTAssertEqual(observed.count, 1)
            let result = try XCTUnwrap(observed.first)
            XCTAssertEqual(result.getPreference(), "default-location")
            XCTAssertTrue(result.getAutoSaveEnabled())
            XCTAssertFalse(result.getSaved())
            XCTAssertEqual(result.getError(), "save default-location")
            XCTAssertTrue(try XCTUnwrap(started.device.getDefaultLocation()).equals(accepted))
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
            XCTAssertFalse(started.device.getConnectEnabled())
        }
    }

    func testNativeInitialAppIntentUsesSdkAutoSaveThenColdLoadWithoutRpc() throws {
        try withFixture { fixture in
            let app = try fixture.openStore("app")
            let initial = try fixture.openStore("extension")
            try fixture.seed(app)
            try fixture.seed(initial)
            let chosen = try fixture.location("named-initial-choice")
            try app.local.setConnectLocation(chosen)
            try app.local.setDefaultLocation(chosen)
            try initial.local.setDefaultLocation(chosen)
            XCTAssertNil(try initial.local.readConnectLocation().getLocation())
            let intent = try fixture.recordIntent(connect: true)
            let first = try fixture.start(initial, intent: intent)
            XCTAssertEqual(first.stage, .sharedDefault)
            XCTAssertEqual(first.events, ["load", "autosave", "checked-mutation", "durable"])
            XCTAssertTrue(first.device.getAutoSave())
            XCTAssertEqual(first.resetCount, 0)
            XCTAssertTrue(first.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(first.device.getConnectLocation()).equals(chosen))
            XCTAssertEqual(initial.local.getByClientJwt(), fixture.initialClient)
            XCTAssertTrue(try XCTUnwrap(app.local.readConnectLocation().getLocation()).equals(chosen))
            try fixture.close(initial)

            // Reopen only the extension store; no app state or intent fallback
            // supplies this second destination. The saved record must suffice.
            let reopened = try fixture.openStore("extension")
            let second = try fixture.start(reopened, intent: nil)
            XCTAssertEqual(second.stage, .saved)
            XCTAssertEqual(second.events, ["load", "autosave", "already-loaded", "durable"])
            XCTAssertNil(second.device.getLastStateSaveResult())
            XCTAssertEqual(second.resetCount, 0)
            XCTAssertTrue(second.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(second.device.getConnectLocation()).equals(chosen))
            XCTAssertTrue(try XCTUnwrap(second.device.getDefaultLocation()).equals(chosen))
            XCTAssertEqual(reopened.local.getByClientJwt(), fixture.initialClient)
        }
    }

    // Load restores the actual consumer without an autosave replay or an
    // enabling-time snapshot write. The remembered default remains distinct.
    func testNativeAlreadySavedExtensionLocationRestoresWithoutRpcOrInitialWrite() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("already-saved-current")
            let remembered = try fixture.location("different-default")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(remembered)
            let result = try fixture.start(store, intent: nil)
            XCTAssertEqual(result.stage, .saved)
            XCTAssertEqual(result.events, ["load", "autosave", "already-loaded", "durable"])
            XCTAssertNil(result.device.getLastStateSaveResult())
            XCTAssertEqual(result.resetCount, 0)
            XCTAssertTrue(result.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(result.device.getConnectLocation()).equals(chosen))
            XCTAssertTrue(try XCTUnwrap(result.device.getDefaultLocation()).equals(remembered))
        }
    }

    func testNativeColdReopenRetainsNamedConsumerDefaultAndDistinctAuthAfterSameOwnerRotation() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("rotation-current")
            let remembered = try fixture.location("rotation-default")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(remembered)
            let first = try fixture.start(store, intent: nil)
            let renewed = try fixture.client(marker: "renewed", issuedAt: 1_800_000_020)
            // Public, real owned DeviceLocal publication/persistence. The
            // separate SDK test covers the API refresh-worker callback itself.
            first.device.setByJwt(renewed)
            XCTAssertEqual(first.device.getClientJwt(), renewed)
            XCTAssertEqual(store.local.getByClientJwt(), renewed)
            XCTAssertEqual(store.local.getByJwt(), fixture.adminClient)
            let keySeed = try XCTUnwrap(store.local.readDeviceLocalKeyMaterial().getKeyMaterial()?.getClientKeySeed())
            try fixture.close(store)

            let reopened = try fixture.openStore("extension")
            XCTAssertEqual(reopened.local.getByClientJwt(), renewed)
            XCTAssertEqual(reopened.local.getByJwt(), fixture.adminClient)
            // The profile still contains the older credential; production
            // checked selection must retain the newer durable same-owner one.
            let second = try fixture.start(reopened, intent: nil)
            XCTAssertEqual(second.resetCount, 0)
            XCTAssertEqual(second.device.getClientJwt(), renewed)
            XCTAssertTrue(second.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(second.device.getConnectLocation()).equals(chosen))
            XCTAssertTrue(try XCTUnwrap(second.device.getDefaultLocation()).equals(remembered))
            XCTAssertTrue(try reopened.local.readDeviceLocalKeyMaterial().getKeyMaterial()?.getClientKeySeed() == keySeed,
                          "cold reopen changed retained key material")
            XCTAssertEqual(reopened.local.getByJwt(), fixture.adminClient)
        }
    }

    func testNativeExplicitDisconnectPreservesDefaultWithoutConstructingConsumer() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("saved-before-disconnect")
            let remembered = try fixture.location("remembered-while-disconnected")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(remembered)
            let result = try fixture.start(store, intent: fixture.recordIntent(connect: false))
            XCTAssertEqual(result.stage, .explicitDisconnect)
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertNil(result.device.getConnectLocation())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertTrue(try XCTUnwrap(result.device.getDefaultLocation()).equals(remembered))
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(remembered))
        }
    }

    func testNativeUnusedCorruptDefaultPreservesConsumerAndMalformedFile() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("current-with-unused-corrupt-default")
            try store.local.setConnectLocation(chosen)
            let path = try fixture.recordPath(store, name: ".default_location")
            let bytes = Data("{private-marker-invalid-default".utf8)
            try bytes.write(to: path)
            let result = try fixture.start(store, intent: nil)
            XCTAssertEqual(result.stage, .saved)
            XCTAssertTrue(result.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(result.device.getConnectLocation()).equals(chosen))
            XCTAssertNil(result.device.getDefaultLocation())
            XCTAssertEqual(try Data(contentsOf: path), bytes)
            XCTAssertTrue(result.reports.contains("default-load=failed"))
            XCTAssertTrue(result.reports.contains("consumer=preserved"))
            XCTAssertFalse(result.reports.joined().contains("private-marker"))
        }
    }

    func testNativeRetiredPostLoadStartupCannotEnableSaveOrOverwriteNewerDefault() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("current")
            let remembered = try fixture.location("old-default")
            let newer = try fixture.location("newer-live-default")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(remembered)
            let running = try fixture.start(store, intent: nil)
            let holder = TunnelRecoverySession<TunnelIntentOwner, TunnelIntent>()
            let ticket = holder.begin(owner: try fixture.owner(running.device.getClientJwt()), savedLocationHasCurrentOwner: true)
            var reports: [String] = []
            var enabled = false
            XCTAssertThrowsError(try loadTunnelPreferences(
                intent: .none, loadOwnedPreferences: true,
                isCurrent: { holder.isCurrent(ticket) },
                persistDisconnect: { XCTFail("not a disconnect") },
                load: {
                    let loaded = try running.device.load()
                    holder.retire(ticket)
                    try running.device.setDefaultLocationChecked(newer)
                    return loaded
                },
                enableAutoSave: { enabled = true },
                report: { reports.append($0 + "=" + $1) }
            ))
            XCTAssertFalse(enabled)
            XCTAssertTrue(running.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(running.device.getDefaultLocation()).equals(newer))
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(newer))
            XCTAssertEqual(reports, ["preferences-load=started", "preferences-load=completed"])
        }
    }

    func testNativeMalformedRequiredSavedLocationCannotBecomeDefaultConsumer() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            try store.local.setDefaultLocation(fixture.location("must-not-be-chosen"))
            let path = try fixture.recordPath(store, name: ".connect_location")
            let bytes = Data("{private-marker-invalid-current".utf8)
            try bytes.write(to: path)
            XCTAssertThrowsError(try fixture.start(store, intent: fixture.recordIntent(connect: true))) { error in
                XCTAssertEqual((error as NSError).localizedDescription, "load connect location")
            }
            let device = try XCTUnwrap(store.device)
            XCTAssertFalse(device.getConnectEnabled())
            XCTAssertNil(device.getConnectLocation())
            XCTAssertFalse(device.getAutoSave())
            XCTAssertNil(device.getLastStateSaveResult())
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testNativeInitiallyEmptyAuthDoesNotLoadOrEraseOrphanLocations() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            let orphan = try fixture.location("unowned-current")
            let orphanDefault = try fixture.location("unowned-default")
            try store.local.setConnectLocation(orphan)
            try store.local.setDefaultLocation(orphanDefault)
            XCTAssertTrue(try store.space.getAuthStateSnapshot().getEmpty())
            let result = try fixture.start(store, intent: nil)
            XCTAssertEqual(result.stage, .localOnly)
            XCTAssertTrue(result.device.getAutoSave())
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertNil(result.device.getConnectLocation())
            XCTAssertNil(result.device.getDefaultLocation())
            XCTAssertTrue(try XCTUnwrap(store.local.readConnectLocation().getLocation()).equals(orphan))
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(orphanDefault))
            XCTAssertTrue(result.reports.contains("preferences-load=skipped-unowned"))
            XCTAssertFalse(result.events.contains("load"))
        }
    }

    // Full-catalog gate: fresh constructor auth must not grant provenance to
    // old non-location security/carrier records. Core-only SDK is insufficient.
    func testNativeInitiallyEmptyAuthDoesNotImportOrphanSecurityOrTransportPolicy() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try store.local.setBlockerEnabled(true)
            let clientPolicy = try XCTUnwrap(SdkDefaultTransportSettings())
            clientPolicy.mode = "h3"
            let providerPolicy = try XCTUnwrap(SdkDefaultProviderTransportSettings())
            providerPolicy.mode = "h1"
            try store.local.setTransportSettings(clientPolicy)
            try store.local.setProviderTransportSettings(providerPolicy)
            let names = [".blocker_enabled", ".transport_settings", ".provider_transport_settings"]
            let before = try names.map { try fixture.existingRecordData(store, name: $0) }
            XCTAssertTrue(try store.space.getAuthStateSnapshot().getEmpty())
            let result = try fixture.start(store, intent: nil)
            XCTAssertEqual(result.stage, .localOnly)
            XCTAssertTrue(result.device.getAutoSave())
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertFalse(result.device.getBlockerEnabled(), "orphan opt-in blocker policy is not current-owner intent")
            XCTAssertEqual(result.device.getTransportSettings()?.mode, SdkDefaultTransportSettings()?.mode)
            XCTAssertEqual(result.device.getProviderTransportSettings()?.mode, SdkDefaultProviderTransportSettings()?.mode)
            XCTAssertEqual(try names.map { try fixture.existingRecordData(store, name: $0) }, before)
            XCTAssertTrue(result.reports.contains("preferences-load=skipped-unowned"))
            XCTAssertFalse(result.events.contains("load"))
        }
    }

    func testNativeOwnedDisconnectedStartupStillLoadsRequiredSecurityAndTransportPolicy() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            try store.local.setBlockerEnabled(true)
            let clientPolicy = try XCTUnwrap(SdkDefaultTransportSettings())
            clientPolicy.mode = "h3"
            let providerPolicy = try XCTUnwrap(SdkDefaultProviderTransportSettings())
            providerPolicy.mode = "h1"
            try store.local.setTransportSettings(clientPolicy)
            try store.local.setProviderTransportSettings(providerPolicy)
            let result = try fixture.start(store, intent: fixture.recordIntent(connect: false))
            XCTAssertEqual(result.stage, .explicitDisconnect)
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertNil(result.device.getConnectLocation())
            XCTAssertTrue(result.device.getBlockerEnabled())
            XCTAssertEqual(result.device.getTransportSettings()?.mode, "h3")
            XCTAssertEqual(result.device.getProviderTransportSettings()?.mode, "h1")
            XCTAssertTrue(result.events.contains("load"))
        }
    }

    func testNativeFirstInstallCurrentConnectSavesNewChoiceWithoutOrphanFallback() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            let orphan = try fixture.location("unowned-current")
            let orphanDefault = try fixture.location("unowned-default")
            try store.local.setConnectLocation(orphan)
            try store.local.setDefaultLocation(orphanDefault)
            let result = try fixture.start(store, intent: fixture.recordIntent(connect: true), allowBestAvailable: true)
            XCTAssertEqual(result.stage, .sharedBestAvailable)
            XCTAssertTrue(result.device.getAutoSave())
            XCTAssertTrue(result.device.getConnectEnabled())
            let current = try XCTUnwrap(result.device.getConnectLocation())
            XCTAssertTrue(try XCTUnwrap(current.connectLocationId).bestAvailable)
            XCTAssertFalse(current.equals(orphan))
            XCTAssertTrue(try XCTUnwrap(store.local.readConnectLocation().getLocation()).equals(current))
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(orphanDefault))
            XCTAssertNil(result.device.getDefaultLocation())
            XCTAssertFalse(result.events.contains("load"))
        }
    }

    func testNativeInitiallyEmptyCurrentDisconnectClearsOnlyCurrentOrphan() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            let orphan = try fixture.location("unowned-current")
            let orphanDefault = try fixture.location("unowned-default")
            try store.local.setConnectLocation(orphan)
            try store.local.setDefaultLocation(orphanDefault)
            let result = try fixture.start(store, intent: fixture.recordIntent(connect: false))
            XCTAssertEqual(result.stage, .explicitDisconnect)
            XCTAssertTrue(result.device.getAutoSave())
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertTrue(try XCTUnwrap(store.local.readDefaultLocation().getLocation()).equals(orphanDefault))
            XCTAssertNil(result.device.getDefaultLocation())
            XCTAssertFalse(result.events.contains("load"))
        }
    }

    func testNativeCurrentDisconnectPreflightRemovesMalformedCurrentBeforeLoad() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let remembered = try fixture.location("default-while-disconnected")
            try store.local.setDefaultLocation(remembered)
            let path = try fixture.recordPath(store, name: ".connect_location")
            try Data("{malformed-current".utf8).write(to: path)
            let result = try fixture.start(store, intent: fixture.recordIntent(connect: false))
            XCTAssertEqual(result.stage, .explicitDisconnect)
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertTrue(try XCTUnwrap(result.device.getDefaultLocation()).equals(remembered))
        }
    }

    func testNativeFailedDefaultWithAbsentCurrentCannotChooseBestAvailable() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let path = try fixture.recordPath(store, name: ".default_location")
            let bytes = Data("{private-marker-invalid-default".utf8)
            try bytes.write(to: path)
            XCTAssertThrowsError(try fixture.start(store, intent: fixture.recordIntent(connect: true)))
            let device = try XCTUnwrap(store.device)
            XCTAssertFalse(device.getConnectEnabled())
            XCTAssertNil(device.getConnectLocation())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertEqual(try Data(contentsOf: path), bytes)
        }
    }

    func testNativeQueuedStartupFinishAdoptsNewScopedConnectWithoutRpc() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("late-connect-default")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(chosen)
            let defaultBytes = try fixture.existingRecordData(store, name: ".default_location")
            _ = try fixture.recordIntent(connect: false)
            let startup = try fixture.queuedStartup(store)
            startup.start()
            let initial = try startup.prepared.result()
            XCTAssertEqual(initial.stage, .explicitDisconnect)
            XCTAssertFalse(initial.device.getConnectEnabled())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertTrue(startup.results.isEmpty)

            let latest = try fixture.recordIntent(connect: true, at: 1_800_000_101)
            startup.finish.drain()
            XCTAssertTrue(startup.results.isEmpty)
            XCTAssertFalse(initial.device.getConnectEnabled(), "finish admission cannot perform SDK reconciliation")
            XCTAssertEqual(startup.worker.count, 1)
            startup.worker.drain()
            let reconciled = try startup.prepared.result()
            XCTAssertEqual(reconciled.stage, .sharedDefault)
            XCTAssertEqual(reconciled.events.filter { $0 == "load" }.count, 1)
            XCTAssertEqual(reconciled.events.filter { $0 == "autosave" }.count, 1)
            XCTAssertEqual(reconciled.resetCount, 0)
            XCTAssertTrue(reconciled.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(reconciled.device.getConnectLocation()).equals(chosen))
            XCTAssertTrue(try XCTUnwrap(store.local.readConnectLocation().getLocation()).equals(chosen))
            XCTAssertEqual(startup.prepared.holder.snapshot(ticket: startup.prepared.ticket)?.observedIntent, latest)
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".default_location"), defaultBytes)
            startup.completeOnAdmittedStack()
        }
    }

    func testNativeQueuedStartupFinishAppliesLateDisconnectBeforeCompletion() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("connected-before-late-disconnect")
            let remembered = try fixture.location("late-disconnect-keeps-default")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(remembered)
            let defaultBytes = try fixture.existingRecordData(store, name: ".default_location")
            _ = try fixture.recordIntent(connect: true)
            let startup = try fixture.queuedStartup(store)
            startup.start()
            XCTAssertTrue(startup.prepared.device.getConnectEnabled())
            XCTAssertNil(startup.prepared.device.getLastStateSaveResult())
            _ = try fixture.recordIntent(connect: false, at: 1_800_000_101)
            startup.finish.drain()
            XCTAssertTrue(startup.prepared.device.getConnectEnabled(), "no SDK mutation may run on finish admission")
            XCTAssertTrue(startup.results.isEmpty)
            startup.worker.drain()
            let result = try startup.prepared.result()
            XCTAssertEqual(result.stage, .explicitDisconnect)
            XCTAssertFalse(result.device.getConnectEnabled())
            XCTAssertNil(result.device.getConnectLocation())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertTrue(try XCTUnwrap(result.device.getDefaultLocation()).equals(remembered))
            XCTAssertEqual(result.events.filter { $0 == "load" }.count, 1)
            XCTAssertEqual(result.events.filter { $0 == "autosave" }.count, 1)
            XCTAssertEqual(result.events.filter { $0 == "checked-mutation" }.count, 1)
            XCTAssertEqual(result.resetCount, 0)
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".default_location"), defaultBytes)
            startup.completeOnAdmittedStack()
        }
    }

    func testNativeQueuedStartupFinishKeepsUnchangedDisconnectLocal() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let remembered = try fixture.location("unchanged-disconnect-default")
            try store.local.setConnectLocation(remembered)
            try store.local.setDefaultLocation(remembered)
            let defaultBytes = try fixture.existingRecordData(store, name: ".default_location")
            _ = try fixture.recordIntent(connect: false)
            let startup = try fixture.queuedStartup(store)
            startup.start()
            let before = try startup.prepared.result()
            let sequence = before.device.getLastStateSaveResult()?.getSequence()
            startup.completeOnAdmittedStack()
            let after = try startup.prepared.result()
            XCTAssertEqual(after.stage, .explicitDisconnect)
            XCTAssertEqual(after.events, before.events)
            XCTAssertEqual(after.device.getLastStateSaveResult()?.getSequence(), sequence)
            XCTAssertFalse(after.device.getConnectEnabled())
            XCTAssertNil(after.device.getConnectLocation())
            XCTAssertNil(try store.local.readConnectLocation().getLocation())
            XCTAssertEqual(after.resetCount, 0)
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".default_location"), defaultBytes)
        }
    }

    func testNativeQueuedStartupFinishRejectsRetiredOwnerWithoutWriting() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let remembered = try fixture.location("retired-startup-default")
            try store.local.setDefaultLocation(remembered)
            _ = try fixture.recordIntent(connect: false)
            let startup = try fixture.queuedStartup(store)
            startup.start()
            let before = try startup.prepared.result()
            let defaultBytes = try fixture.existingRecordData(store, name: ".default_location")
            let currentPath = try fixture.recordPath(store, name: ".connect_location")
            XCTAssertFalse(FileManager.default.fileExists(atPath: currentPath.path))
            _ = try fixture.recordIntent(connect: true, at: 1_800_000_101)
            startup.prepared.holder.retire(startup.prepared.ticket)
            startup.worker.drain()
            XCTAssertTrue(store.closed, "actual SDK cleanup must finish while the main block is still held")
            XCTAssertTrue(startup.prepared.device.getDone())
            XCTAssertEqual(startup.results.count, 1)
            guard case .failure(let error)? = startup.results.first,
                  case TunnelLocalAuthIdentityError.superseded = error else {
                return XCTFail("retired startup must fail")
            }
            XCTAssertEqual(startup.finish.count, 1)
            startup.finish.drain()
            XCTAssertEqual(startup.worker.count, 0)
            XCTAssertEqual(startup.results.count, 1)
            XCTAssertEqual(try startup.prepared.result().events, before.events)
            XCTAssertFalse(FileManager.default.fileExists(atPath: currentPath.path))
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".default_location"), defaultBytes)
        }
    }

    func testNativeQueuedStartupFinishPreservesSameOwnerRotation() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let remembered = try fixture.location("rotated-owner-late-connect")
            try store.local.setDefaultLocation(remembered)
            let defaultBytes = try fixture.existingRecordData(store, name: ".default_location")
            _ = try fixture.recordIntent(connect: false)
            let startup = try fixture.queuedStartup(store)
            startup.start()
            let seed = try XCTUnwrap(store.local.readDeviceLocalKeyMaterial().getKeyMaterial()?.getClientKeySeed())
            let renewed = try fixture.client(marker: "queued-finish-renewed", issuedAt: 1_800_000_020)
            startup.prepared.device.setByJwt(renewed)
            _ = try fixture.recordIntent(connect: true, at: 1_800_000_101)
            startup.finish.drain()
            startup.worker.drain()
            let result = try startup.prepared.result()
            XCTAssertEqual(result.resetCount, 0)
            XCTAssertEqual(result.events.filter { $0 == "load" }.count, 1)
            XCTAssertEqual(result.events.filter { $0 == "autosave" }.count, 1)
            XCTAssertTrue(result.device.getClientJwt() == renewed, "rotation must retain the current device credential")
            XCTAssertTrue(store.local.getByClientJwt() == renewed, "rotation must remain durable")
            XCTAssertTrue(store.local.getByJwt() == fixture.adminClient, "admin credential must remain distinct")
            XCTAssertTrue(try store.local.readDeviceLocalKeyMaterial().getKeyMaterial()?.getClientKeySeed() == seed,
                          "finish reconciliation must preserve device keys")
            XCTAssertTrue(result.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(store.local.readConnectLocation().getLocation()).equals(remembered))
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".default_location"), defaultBytes)
            startup.completeOnAdmittedStack()
        }
    }

    func testNativeQueuedStartupFinishKeepsHealthySavedConsumerWithoutReplay() throws {
        try withFixture { fixture in
            let store = try fixture.openStore("extension")
            try fixture.seed(store)
            let chosen = try fixture.location("healthy-queued-current")
            let remembered = try fixture.location("healthy-queued-default")
            try store.local.setConnectLocation(chosen)
            try store.local.setDefaultLocation(remembered)
            let currentBytes = try fixture.existingRecordData(store, name: ".connect_location")
            let defaultBytes = try fixture.existingRecordData(store, name: ".default_location")
            let startup = try fixture.queuedStartup(store)
            startup.start()
            let before = try startup.prepared.result()
            XCTAssertEqual(before.stage, .saved)
            XCTAssertEqual(before.events, ["load", "autosave", "already-loaded", "durable"])
            startup.completeOnAdmittedStack()
            let after = try startup.prepared.result()
            XCTAssertEqual(after.events, before.events)
            XCTAssertNil(after.device.getLastStateSaveResult())
            XCTAssertEqual(after.resetCount, 0)
            XCTAssertTrue(after.device.getConnectEnabled())
            XCTAssertTrue(try XCTUnwrap(after.device.getConnectLocation()).equals(chosen))
            XCTAssertTrue(try XCTUnwrap(after.device.getDefaultLocation()).equals(remembered))
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".connect_location"), currentBytes)
            XCTAssertEqual(try fixture.existingRecordData(store, name: ".default_location"), defaultBytes)
        }
    }

    // SDK checked mutations deliver synchronously before returning. Keep the
    // recorder thread-safe so an unexpected callback does not itself race.
    private final class SaveObserver: NSObject, SdkLocalStateSaveListenerProtocol {
        private let lock = NSLock()
        private var results: [SdkDeviceLocalSaveResult] = []

        func localStateSaved(_ result: SdkDeviceLocalSaveResult?) {
            guard let result else {
                XCTFail("save listener received a missing operation result")
                return
            }
            lock.lock()
            defer { lock.unlock() }
            results.append(result)
        }

        func snapshot() -> [SdkDeviceLocalSaveResult] {
            lock.lock()
            defer { lock.unlock() }
            return results
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try body(fixture)
    }

    private final class Store {
        let directory: URL
        let manager: SdkNetworkSpaceManager
        let space: SdkNetworkSpace
        let local: SdkLocalState
        var device: SdkDeviceLocal?
        var closed = false

        init(directory: URL) throws {
            self.directory = directory
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let createdManager = try XCTUnwrap(SdkNewNetworkSpaceManager(directory.path))
            let values = SdkNetworkSpaceValues()
            values.apiUrl = "http://127.0.0.1:1"
            values.platformUrl = "ws://127.0.0.1:1"
            do {
                let key = try XCTUnwrap(SdkNewNetworkSpaceKey("startup-replay.test", "test"))
                let createdSpace = try XCTUnwrap(createdManager.updateNetworkSpaceValues(key, values: values))
                let createdLocal = try XCTUnwrap(createdSpace.getAsyncLocalState()?.getLocalState())
                manager = createdManager
                space = createdSpace
                local = createdLocal
            } catch {
                createdManager.close()
                throw error
            }
        }
    }

    private struct Started {
        let device: SdkDeviceLocal
        let stage: TunnelDestinationStage
        let events: [String]
        let reports: [String]
        let resetCount: Int
    }

    private struct PreparedStartup {
        let device: SdkDeviceLocal
        let holder: TunnelRecoverySession<TunnelIntentOwner, TunnelIntent>
        let ticket: TunnelRecoverySession<TunnelIntentOwner, TunnelIntent>.Ticket
        let observe: () throws -> Void
        let result: () throws -> Started
    }

    // Two manually drained queues expose the actual production continuation
    // and recovery-session finish adapter. SDK observation uses the existing
    // fixture's checked Load/reconciliation, not a supplied expected location.
    // Completion deliberately performs no SDK reads or second finish enqueue.
    private final class QueuedStartup {
        let prepared: PreparedStartup
        let worker = Queue()
        let finish = Queue()
        var results: [Result<Void, Error>] = []
        private var startup: TunnelAuthStartupContinuation?

        init(prepared: PreparedStartup, defaults: UserDefaults, cleanup: TunnelStartupCleanup) {
            self.prepared = prepared
            let startup = TunnelAuthStartupContinuation(
                enqueue: worker.enqueue,
                subscribe: { _, _ in {} },
                scheduleDeadline: { _ in {} },
                isCurrent: { prepared.holder.isCurrent(prepared.ticket) },
                observe: prepared.observe,
                finishAdmission: prepared.holder.startupFinishAdmission(
                    ticket: prepared.ticket, enqueue: finish.enqueue,
                    readIntent: { try TunnelIntentStore.loadChecked(from: defaults) }
                ),
                completion: { [weak self] result in
                    prepared.holder.clearAuthStartup(prepared.ticket)
                    if case .success = result { cleanup.commit() }
                    else { cleanup.cleanUpNow() }
                    self?.results.append(result)
                }
            )
            self.startup = startup
            XCTAssertTrue(prepared.holder.installAuthStartup(startup, ticket: prepared.ticket))
        }

        func start() { startup?.start() }

        func completeOnAdmittedStack() {
            XCTAssertEqual(finish.count, 1)
            finish.enqueue {
                XCTAssertEqual(self.results.count, 1, "completion must precede the next finish-queue block")
                guard case .success? = self.results.first else { return XCTFail("startup must succeed") }
                XCTAssertEqual(self.finish.count, 0, "no second main hop may reopen admission")
            }
            finish.drain()
            XCTAssertEqual(worker.count, 0)
        }
    }

    private final class Queue {
        private var work: [() -> Void] = []
        var count: Int { work.count }
        func enqueue(_ block: @escaping () -> Void) { work.append(block) }
        func drain() {
            for _ in 0..<100 {
                guard !work.isEmpty else { return }
                work.removeFirst()()
            }
            XCTFail("unexpected unbounded startup work")
        }
    }

    private final class Fixture {
        let directory: URL
        let instance: SdkId
        let initialClient: String
        let adminClient: String
        let suiteName: String
        let defaults: UserDefaults
        let networkJson = "{\"key\":{\"host_name\":\"startup-replay.test\",\"env_name\":\"test\"}}"
        private var stores: [Store] = []

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "native-cold-restore-" + UUID().uuidString, isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            instance = try XCTUnwrap(SdkNewId())
            initialClient = try Self.token(client: true, marker: "initial", issuedAt: 1_800_000_000)
            adminClient = try Self.token(client: false, marker: "separate-admin", issuedAt: 1_800_000_000)
            suiteName = "network.ur.tests.cold-restore." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        }

        func openStore(_ name: String) throws -> Store {
            let store = try Store(directory: directory.appendingPathComponent(name, isDirectory: true))
            stores.append(store)
            return store
        }

        func seed(_ store: Store) throws {
            try store.local.setByJwt(adminClient)
            try store.local.setByClientJwt(initialClient)
            try store.local.setInstanceId(instance)
            let keys = try XCTUnwrap(SdkNewDeviceLocalKeyMaterial(Data(repeating: 7, count: 32), nil, nil))
            try store.local.setDeviceLocalKeyMaterial(keys)
            // Disable all test DNS egress before construction, rather than
            // exercising public DoH warm-up. This does not test DNS health.
            try store.local.setDnsResolverSettings(SdkDnsResolverSettings())
            try store.local.setBlockerEnabled(false)
        }

        func location(_ name: String) throws -> SdkConnectLocation {
            let id = SdkConnectLocationId()
            id.locationId = try XCTUnwrap(SdkNewId())
            let location = SdkConnectLocation()
            location.connectLocationId = id
            location.name = name
            return location
        }

        func owner(_ client: String) throws -> TunnelIntentOwner {
            try XCTUnwrap(TunnelIntentOwner.make(
                instanceId: instance.string(), clientJwt: client, networkSpaceJson: networkJson
            ))
        }

        func recordIntent(connect: Bool, at seconds: TimeInterval = 1_800_000_100) throws -> TunnelIntent {
            let written = TunnelIntentStore.record(
                connect: connect, source: TunnelIntentStore.sourceApp,
                owner: try owner(initialClient), at: Date(timeIntervalSince1970: seconds),
                in: defaults
            )
            let loaded = try XCTUnwrap(TunnelIntentStore.loadChecked(from: defaults))
            XCTAssertEqual(loaded, written)
            return loaded
        }

        func start(_ store: Store, intent: TunnelIntent?, allowBestAvailable: Bool = false) throws -> Started {
            let prepared = try prepareStartup(store, readIntent: { intent }, allowBestAvailable: allowBestAvailable)
            defer { prepared.holder.retire(prepared.ticket) }
            try prepared.observe()
            try store.local.setDeviceLocalKeyMaterial(prepared.device.getKeyMaterial())
            return try prepared.result()
        }

        func queuedStartup(_ store: Store) throws -> QueuedStartup {
            let prepared = try prepareStartup(store, readIntent: { try TunnelIntentStore.loadChecked(from: self.defaults) })
            let cleanup = TunnelStartupCleanup {
                do { try self.close(store) }
                catch { XCTFail("failed startup owner did not join during cleanup") }
            }
            return QueuedStartup(prepared: prepared, defaults: defaults, cleanup: cleanup)
        }

        private func prepareStartup(
            _ store: Store, readIntent: @escaping () throws -> TunnelIntent?, allowBestAvailable: Bool = false
        ) throws -> PreparedStartup {
            XCTAssertFalse(store.closed)
            XCTAssertNil(store.device)
            let configuredOwner = try owner(initialClient)
            var initialSnapshot: SdkLocalAuthStateSnapshot?
            var resetCount = 0
            var material: SdkDeviceLocalKeyMaterial?
            let device: SdkDeviceLocal = try prepareTunnelLocalAuthState(
                configuredInstanceId: instance.string(),
                readAuthIdentity: {
                    let snapshot = try store.space.getAuthStateSnapshot()
                    initialSnapshot = snapshot
                    if snapshot.getEmpty() {
                        return TunnelLocalAuthIdentitySnapshot(isEmpty: true, instanceId: nil)
                    }
                    let storedOwner = try self.owner(snapshot.getByClientJwt())
                    return TunnelLocalAuthIdentitySnapshot(
                        isEmpty: snapshot.getEmpty(), instanceId: snapshot.getInstanceId()?.string(),
                        knownClientOwnerConflict: !storedOwner.matches(configuredOwner)
                    )
                },
                clearStaleState: {
                    resetCount += 1
                    let snapshot = try XCTUnwrap(initialSnapshot)
                    let result = try store.space.resetLocalStateIfCurrent(snapshot)
                    try requireTunnelResetCompleted(result.getReset())
                    material = result.getDeviceLocalKeyMaterial()
                },
                selectClientJwt: {
                    try checkedTunnelSdkValue {
                        store.local.selectClientJwt(forInstance: self.initialClient, instanceId: self.instance, error: $0)
                    }
                },
                startSession: { selected in
                    if resetCount == 0 { material = try store.local.readDeviceLocalKeyMaterial().getKeyMaterial() }
                    var error: NSError?
                    let created = SdkNewDeviceLocalWithMemoryTarget(
                        store.space, selected, "cold-restore-test", "test", "0",
                        self.instance, false, material, 20 * 1024 * 1024, &error
                    )
                    // Register even a partial result before NSError handling;
                    // the store's existing cleanup closes and joins this owner
                    // and retains storage if the bounded join fails.
                    if let created { store.device = created }
                    if let error { throw error }
                    return try XCTUnwrap(created)
                }
            )
            store.device = device
            XCTAssertFalse(device.getConnectEnabled())
            XCTAssertNil(device.getConnectLocation())
            let acceptedOwner = try owner(device.getClientJwt())
            let holder = TunnelRecoverySession<TunnelIntentOwner, TunnelIntent>()
            let ticket = holder.begin(
                owner: acceptedOwner,
                savedLocationHasCurrentOwner: !(initialSnapshot?.getEmpty() ?? true) && resetCount == 0
            )
            let currentSnapshot = { () throws -> SdkLocalAuthStateSnapshot in
                guard holder.isCurrent(ticket), !device.getDone() else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                let snapshot = try store.space.getAuthStateSnapshot()
                guard snapshot.getInstanceId()?.string() == self.instance.string(),
                      acceptedOwner.matches(try self.owner(snapshot.getByClientJwt())) else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                return snapshot
            }
            let admitIntent = { (intent: TunnelIntent?) -> TunnelDestinationIntent in
                if let intent, intent.applies(to: acceptedOwner) {
                    return intent.connect ? .connect : .disconnect
                }
                return .none
            }
            var events: [String] = []
            var reports: [String] = []
            var stage: TunnelDestinationStage?
            var initialPreferencesPrepared = false
            let preparePreferences = { () throws -> Void in
                guard let state = holder.snapshot(ticket: ticket) else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                let snapshot = try currentSnapshot()
                let intent = try readIntent()
                let loaded: SdkDeviceLocalLoadResult? = try loadTunnelPreferences(
                    intent: admitIntent(intent),
                    loadOwnedPreferences: !(initialSnapshot?.getEmpty() ?? true) || resetCount != 0,
                    isCurrent: {
                        guard holder.isCurrent(state.destinationTicket), !device.getDone() else { return false }
                        return try readIntent() == intent
                    },
                    persistDisconnect: { try snapshot.setConnectLocation(nil) },
                    load: {
                        events.append("load")
                        XCTAssertFalse(device.getAutoSave())
                        // Let the checked read throw to the caller; XCTUnwrap's
                        // autoclosure would record an extra failure before rethrowing.
                        let result = try device.load()
                        XCTAssertTrue(result.getLoaded())
                        XCTAssertNil(device.getLastStateSaveResult())
                        return result
                    },
                    enableAutoSave: {
                        try device.setAutoSave(true)
                        XCTAssertTrue(device.getAutoSave())
                        events.append("autosave")
                        if initialSnapshot?.getEmpty() == true {
                            // Explicit isolated fixture policy after autosave;
                            // skipped orphan preferences cannot supply DNS policy.
                            device.setDnsResolverSettings(SdkDnsResolverSettings())
                        }
                    },
                    report: { reports.append($0 + "=" + $1) }
                )
                let defaultUnavailable = loaded.map { !$0.getDefaultError().isEmpty } ?? false
                XCTAssertTrue(holder.observeDefaultPreference(ticket, unavailable: defaultUnavailable))
                if defaultUnavailable {
                    reports.append("default-load=failed")
                    reports.append("consumer=preserved")
                }
            }
            let reconcileDestination = { () throws -> Void in
                guard let state = holder.snapshot(ticket: ticket) else {
                    throw TunnelLocalAuthIdentityError.superseded
                }
                _ = try currentSnapshot()
                let intent = try readIntent()
                let plan = try restoreTunnelDestination(
                    intent: admitIntent(intent), savedLocationHasCurrentOwner: state.savedLocationHasCurrentOwner,
                    loadSaved: { device.getConnectLocation() },
                    loadDefault: {
                        guard !state.defaultPreferenceUnavailable else { throw TunnelLocalAuthIdentityError.unavailable }
                        return device.getDefaultLocation()
                    },
                    bestAvailable: {
                        XCTAssertTrue(allowBestAvailable, "named destination fixtures must not choose arbitrary best available")
                        let location = SdkConnectLocation()
                        let id = SdkConnectLocationId()
                        id.bestAvailable = true
                        location.connectLocationId = id
                        return location
                    },
                    isCurrent: {
                        guard holder.isCurrent(state.destinationTicket), !device.getDone() else { return false }
                        do { return try readIntent() == intent }
                        catch {
                            reports.append("intent-load=failed")
                            return false
                        }
                    },
                    apply: { plan in
                        let location = plan.location
                        XCTAssertTrue(device.getAutoSave())
                        guard holder.acceptDestination(
                            state.destinationTicket, present: location != nil, observedIntent: intent,
                            savedLocationIsVerified: plan.stage == .saved
                        ) else {
                            throw TunnelLocalAuthIdentityError.superseded
                        }
                        if plan.stage == .saved && device.getConnectEnabled() {
                            events.append("already-loaded")
                        } else if plan.stage == .localOnly && device.getConnectLocation() == nil {
                            events.append("local")
                        } else {
                            if location != nil && device.getConnectLocation() != nil && !device.getConnectEnabled() {
                                try device.reconnectChecked(location)
                            } else {
                                try device.setConnectLocationChecked(location)
                            }
                            let saved = try XCTUnwrap(device.getLastStateSaveResult())
                            XCTAssertTrue(saved.getAutoSaveEnabled())
                            XCTAssertTrue(saved.getSaved())
                            XCTAssertTrue(saved.getError().isEmpty)
                            events.append("checked-mutation")
                        }
                        if let location {
                            // The SDK owns the inside-operation commit-before-live
                            // proof. This native boundary checks actual durability
                            // at return, before any listener or RPC is exposed.
                            let saved = try XCTUnwrap(store.local.readConnectLocation().getLocation())
                            XCTAssertTrue(saved.equals(location))
                            let bytes = try Data(contentsOf: self.recordPath(store, name: ".connect_location"))
                            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                            // The existing Go schema omits an empty name (including
                            // best available), but retains a named selection verbatim.
                            if location.name.isEmpty {
                                XCTAssertNil(object["name"])
                            } else {
                                XCTAssertEqual(object["name"] as? String, location.name)
                            }
                            events.append("durable")
                        } else if plan.stage == .explicitDisconnect {
                            XCTAssertNil(try store.local.readConnectLocation().getLocation())
                        }
                    },
                    report: { reports.append($0 + "=" + $1) }
                )
                stage = plan.stage
            }
            return PreparedStartup(
                device: device, holder: holder, ticket: ticket,
                observe: {
                    if !initialPreferencesPrepared {
                        try preparePreferences()
                        initialPreferencesPrepared = true
                    }
                    try reconcileDestination()
                },
                result: {
                    Started(device: device, stage: try XCTUnwrap(stage), events: events, reports: reports, resetCount: resetCount)
                }
            )
        }

        func recordPath(_ store: Store, name: String) throws -> URL {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: store.directory, includingPropertiesForKeys: nil
            ))
            let envelopes = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == ".auth_state" }
            XCTAssertEqual(envelopes.count, 1)
            return try XCTUnwrap(envelopes.first).deletingLastPathComponent().appendingPathComponent(name)
        }

        func existingRecordData(_ store: Store, name: String) throws -> Data {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: store.directory, includingPropertiesForKeys: nil))
            let records = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == name }
            XCTAssertEqual(records.count, 1)
            return try Data(contentsOf: XCTUnwrap(records.first))
        }

        func client(marker: String, issuedAt: Int64) throws -> String {
            try Self.token(client: true, marker: marker, issuedAt: issuedAt)
        }

        func close(_ store: Store) throws {
            guard !store.closed else { return }
            store.device?.close()
            if let device = store.device {
                guard device.wait(forClose: 5_000) else {
                    XCTFail("old SDK owner failed bounded join")
                    throw TunnelLocalAuthIdentityError.unavailable
                }
                XCTAssertTrue(device.getDone())
            }
            store.manager.close()
            store.closed = true
        }

        func cleanUp() {
            for store in stores.reversed() where !store.closed {
                do { try close(store) } catch { XCTFail("fixture SDK cleanup failed") }
            }
            defaults.removePersistentDomain(forName: suiteName)
            if stores.allSatisfy({ $0.closed }) {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        private static func token(client: Bool, marker: String, issuedAt: Int64) throws -> String {
            var claims: [String: Any] = [
                "network_id": "00000000-0000-0000-0000-000000000004",
                "user_id": "00000000-0000-0000-0000-000000000003",
                "iat": issuedAt, "exp": Int64(2_000_000_000), "marker": marker
            ]
            if client {
                claims["client_id"] = "00000000-0000-0000-0000-000000000001"
                claims["device_id"] = "00000000-0000-0000-0000-000000000002"
            }
            func encode(_ bytes: Data) -> String {
                bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
            let payload = try JSONSerialization.data(withJSONObject: claims)
            return encode(header) + "." + encode(payload) + "."
        }
    }
}
