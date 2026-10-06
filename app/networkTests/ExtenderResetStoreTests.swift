//
//  ExtenderResetStoreTests.swift
//  networkTests
//
//  The "Reset extenders" action of Account > Extenders (EXTENDER.md E7), on
//  the store's side: the button only asks, the reset runs on the
//  confirmation's action alone and one at a time, and the form then shows
//  what the reset left over any unsaved edit. The private extender is read
//  back from a real network space in a private directory, which the sdk's own
//  reset clears (no Keychain, network or NetworkExtension access).
//
//  What a reset clears is the sdk's (extender_reset_test.go there); what is
//  pinned here is the app's side of it.
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

private enum ExtenderResetFixtures {

    static func stringList(_ strings: [String]) -> SdkStringList? {
        let list = SdkNewStringList()
        for string in strings {
            list?.add(string)
        }
        return list
    }

    /// The settings before the reset: every value configured.
    static func configuredSettings() -> SdkExtenderSettings {
        let settings = SdkExtenderSettings()
        settings.dnsName = "extender.operator.example"
        settings.dnsNameDefault = false
        settings.gossipUrl = "https://gossip.operator.example"
        settings.gossipUrlDefault = false
        settings.hosts = stringList(["192.0.2.10", "extender-a.example"])
        settings.networkHost = "network.example"
        settings.rootPublicKeysDefault = false
        return settings
    }

    /// The settings a reset leaves: every value the default, no hosts.
    static func resetSettings() -> SdkExtenderSettings {
        let settings = SdkExtenderSettings()
        settings.dnsName = "extender.network.example"
        settings.dnsNameDefault = true
        settings.gossipUrl = "https://gossip.network.example"
        settings.gossipUrlDefault = true
        settings.hosts = stringList([])
        settings.networkHost = "network.example"
        settings.rootPublicKeysDefault = true
        return settings
    }

    static let configuredFields = ExtenderSettingsFields(
        dnsName: "extender.operator.example",
        gossipUrl: "https://gossip.operator.example",
        hostsText: "192.0.2.10\nextender-a.example"
    )

    /// the default fields are empty, with the defaults behind them
    static let resetPlaceholders = ExtenderSettingsPlaceholders(
        dnsName: "extender.network.example",
        gossipUrl: "https://gossip.network.example",
        networkHost: "network.example"
    )

    static let privateExtender = PrivateExtenderFields(ip: "192.0.2.1", secret: "private-secret")
}

/// The sdk controller's side of the store. Its reset does to the space what
/// the sdk's does: `ExtenderViewController.ResetExtenders` resets the
/// device's space, which is the one the screen reads the private extender
/// from. It answers with the settings the reset leaves. With
/// `holdFirstReset` the first reset waits for `releaseReset`, so a test can
/// act while it is in flight, and any later one runs through, so a second
/// reset the store should not have started is counted rather than stuck. The
/// reset runs off the main actor; the lock guards only the count.
private final class ExtenderResetTestingController: ExtenderSettingsController, @unchecked Sendable {
    private let networkSpace: SdkNetworkSpace
    private let holdFirstReset: Bool
    /// signaled by every reset as it starts
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    private let stateLock = NSLock()
    private var resets = 0

    init(networkSpace: SdkNetworkSpace, holdFirstReset: Bool = false) {
        self.networkSpace = networkSpace
        self.holdFirstReset = holdFirstReset
    }

    var resetCount: Int {
        stateLock.withLock { resets }
    }

    func getSettings() -> SdkExtenderSettings? {
        resetCount == 0 ? ExtenderResetFixtures.configuredSettings() : ExtenderResetFixtures.resetSettings()
    }

    func resetExtenders() -> SdkExtenderSettings? {
        let held = stateLock.withLock {
            resets += 1
            return holdFirstReset && resets == 1
        }
        started.signal()
        if held {
            release.wait()
        }
        _ = networkSpace.resetExtenders()
        return ExtenderResetFixtures.resetSettings()
    }

    /// Waits off the main actor for a reset to start: true once one has. A
    /// store that never starts one gets false after `timeout`, which fails the
    /// test instead of hanging it; a passing test never waits that long.
    func resetStarted(timeout: DispatchTimeInterval = .seconds(60)) async -> Bool {
        let started = started
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    func releaseReset() {
        release.signal()
    }

    // not what these tests drive

    func setSettings(_ dnsName: String?, gossipUrl: String?, hosts: SdkStringList?) -> SdkExtenderSettings? {
        nil
    }

    func buildShare(_ includeSettings: Bool) -> SdkExtenderShareResult? {
        nil
    }

    func decodeShare(_ text: String?) -> SdkExtenderShareDecodeResult? {
        nil
    }

    func importShare(_ text: String?, useSettings: Bool) -> SdkExtenderImportResult? {
        nil
    }
}

@MainActor
struct ExtenderResetStoreTests {

    /// A device manager whose active space is a real one with a private
    /// extender, under its own manager in a private directory. Its host is a
    /// single label, which runs no extender network client or node, so a reset
    /// starts nothing that dials.
    private func withDeviceManager(
        _ body: (_ deviceManager: DeviceManager, _ networkSpace: SdkNetworkSpace) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtenderResetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let networkSpaceManager = try #require(SdkNewNetworkSpaceManager(directory.path))
        defer {
            networkSpaceManager.close()
        }
        let values = SdkNetworkSpaceValues()
        let netExtender = SdkNetExtender()
        netExtender.ip = ExtenderResetFixtures.privateExtender.ip
        netExtender.secret = ExtenderResetFixtures.privateExtender.secret
        values.netExtender = netExtender
        let key = try #require(SdkNewNetworkSpaceKey("test", "main"))
        let networkSpace = try #require(networkSpaceManager.updateNetworkSpaceValues(key, values: values))

        let deviceManager = DeviceManager(startupMode: .production, automaticallyInitialize: false)
        deviceManager.setActiveNetworkSpace(networkSpace)
        try await body(deviceManager, networkSpace)
    }

    /// The store as the screen holds it, driving `controller` in place of the
    /// device's.
    private func openStore(
        _ deviceManager: DeviceManager,
        _ controller: ExtenderSettingsController,
        close: @escaping () -> Void = {}
    ) -> ExtenderSettingsStore {
        let store = ExtenderSettingsStore()
        store.setup(deviceManager)
        store.attach(controller, close: close)
        return store
    }

    @Test func theButtonOnlyAsks() async throws {
        try await withDeviceManager { deviceManager, networkSpace in
            let controller = ExtenderResetTestingController(networkSpace: networkSpace)
            let store = openStore(deviceManager, controller)
            #expect(store.loaded)
            #expect(store.fields == ExtenderResetFixtures.configuredFields)
            #expect(store.privateExtender == ExtenderResetFixtures.privateExtender)
            #expect(!store.confirmingResetExtenders)

            store.requestResetExtenders()

            #expect(store.confirmingResetExtenders)
            #expect(controller.resetCount == 0)
            #expect(store.fields == ExtenderResetFixtures.configuredFields)
            #expect(store.privateExtender == ExtenderResetFixtures.privateExtender)
            #expect(networkSpace.getNetExtender()?.ip == ExtenderResetFixtures.privateExtender.ip)
            #expect(networkSpace.getExtenderResetId() == "")
        }
    }

    // Cancel closes the confirmation through its binding, which resets nothing
    @Test func aCancelledConfirmationResetsNothing() async throws {
        try await withDeviceManager { deviceManager, networkSpace in
            let controller = ExtenderResetTestingController(networkSpace: networkSpace)
            let store = openStore(deviceManager, controller)
            store.fields.hostsText = "typed.example"

            store.requestResetExtenders()
            store.confirmingResetExtenders = false

            #expect(controller.resetCount == 0)
            #expect(!store.resettingExtenders)
            // the unsaved edit stays
            #expect(store.fields.hostsText == "typed.example")
            #expect(store.privateExtender == ExtenderResetFixtures.privateExtender)
            #expect(networkSpace.getNetExtender()?.ip == ExtenderResetFixtures.privateExtender.ip)
            #expect(networkSpace.getExtenderResetId() == "")
        }
    }

    // the confirmation's action resets through the controller, and the form
    // shows what the reset left over the unsaved edits: every setting its
    // default, and no private extender, as the space now holds
    @Test func theConfirmedResetShowsWhatItLeft() async throws {
        try await withDeviceManager { deviceManager, networkSpace in
            let controller = ExtenderResetTestingController(networkSpace: networkSpace)
            let store = openStore(deviceManager, controller)
            store.fields.dnsName = "typed-extender.example"
            store.fields.hostsText = "typed.example"
            store.privateExtender = PrivateExtenderFields(ip: "198.51.100.1", secret: "typed-secret")
            store.requestResetExtenders()

            #expect(await store.resetExtenders())

            #expect(controller.resetCount == 1)
            #expect(!store.confirmingResetExtenders)
            #expect(!store.resettingExtenders)
            #expect(store.loaded)
            #expect(store.fields == ExtenderSettingsFields())
            #expect(store.placeholders == ExtenderResetFixtures.resetPlaceholders)
            // the sdk's reset cleared the space's private extender in place,
            // and the form read it back
            #expect(networkSpace.getNetExtender() == nil)
            #expect(networkSpace.getExtenderResetId() != "")
            #expect(store.privateExtender == PrivateExtenderFields())
        }
    }

    // before the settings load there is nothing to reset: the button does not
    // ask, and the action resets nothing
    @Test func nothingResetsBeforeTheSettingsLoad() async throws {
        try await withDeviceManager { deviceManager, networkSpace in
            // the manager has no device, so the screen opens no controller
            let store = ExtenderSettingsStore()
            store.setup(deviceManager)
            #expect(!store.loaded)

            store.requestResetExtenders()
            #expect(!store.confirmingResetExtenders)
            #expect(await store.resetExtenders() == false)

            #expect(networkSpace.getNetExtender()?.ip == ExtenderResetFixtures.privateExtender.ip)
            #expect(networkSpace.getExtenderResetId() == "")
        }
    }

    // while a reset runs a press neither asks nor resets again, and the form
    // reports it running, which holds Save
    @Test func aResetRunsOneAtATime() async throws {
        try await withDeviceManager { deviceManager, networkSpace in
            let controller = ExtenderResetTestingController(networkSpace: networkSpace, holdFirstReset: true)
            let store = openStore(deviceManager, controller)

            let first = Task {
                await store.resetExtenders()
            }
            try #require(await controller.resetStarted())
            #expect(store.resettingExtenders)

            store.requestResetExtenders()
            #expect(!store.confirmingResetExtenders)
            #expect(await store.resetExtenders() == false)

            controller.releaseReset()
            #expect(await first.value)
            #expect(controller.resetCount == 1)
            #expect(!store.resettingExtenders)
            #expect(store.fields == ExtenderSettingsFields())
            #expect(store.privateExtender == PrivateExtenderFields())
        }
    }

    // a reset that finishes after the screen closed still ran, so the screen
    // says so, but it shows nothing on the closed form; the close released
    // the controller, which no later press reaches
    @Test func aResetThatFinishesAfterTheScreenClosedShowsNothing() async throws {
        try await withDeviceManager { deviceManager, networkSpace in
            let controller = ExtenderResetTestingController(networkSpace: networkSpace, holdFirstReset: true)
            var closes = 0
            let store = openStore(deviceManager, controller, close: { closes += 1 })

            let first = Task {
                await store.resetExtenders()
            }
            try #require(await controller.resetStarted())
            store.reset()
            #expect(closes == 1)

            controller.releaseReset()
            #expect(await first.value)
            #expect(controller.resetCount == 1)
            #expect(!store.loaded)
            #expect(store.fields == ExtenderSettingsFields())
            #expect(store.placeholders == .empty)
            #expect(store.privateExtender == PrivateExtenderFields())

            #expect(await store.resetExtenders() == false)
            #expect(controller.resetCount == 1)
            #expect(closes == 1)
        }
    }
}
