//
//  DeviceStoreDeviceCallTests.swift
//  networkTests
//

import Combine
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// The device stores make no device call on the main actor after their
/// setup (owner report 2026-10-16: "when connect is tapped, the view should
/// immediately change to the connection state").
///
/// On the sdk's DeviceRemote every getter, setter, listener add and close
/// takes the device's state lock, which a connect or disconnect command keeps
/// through its rpc to the extension, up to the sdk's 60 s rpc timeout. Made on
/// the main actor while one is held, a call froze it for as long. Here the
/// stores' device work queue is held (`HeldDeviceWork`) as a held command
/// holds the connect view model's command queue, and the fake device records
/// each call made on the main thread. Nothing waits on time.
@MainActor
@Suite(.serialized)
struct DeviceStoreDeviceCallTests {

    typealias FakeDevice = ConnectTapStateTests.FakeDevice

    /// A device work queue held until `release`, as a held command holds the
    /// command queue. A test that ends early (a failed requirement) releases
    /// it at deinit: a queue released while held crashes the test process.
    final class HeldDeviceWork {
        let queue = DispatchQueue(label: "network.ur.test.device-store-work")
        private var held = true

        init() {
            queue.suspend()
        }

        deinit {
            if held {
                queue.resume()
            }
        }

        /// Lets the queued work run, and what is queued later.
        func release() {
            if held {
                held = false
                queue.resume()
            }
        }

        /// Holds the queue again, once its work so far has run.
        func hold() {
            if !held {
                held = true
                queue.suspend()
            }
        }

        /// Releases the queue and waits for the work queued so far, and for
        /// what it handed to the main queue.
        func run() async {
            release()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }

        /// Runs the queue until a store's chain of reads is through: a read
        /// that lands can queue the one wanted after it.
        func settle() async {
            for _ in 0..<3 {
                await run()
            }
        }
    }

    /// The app's own local state, as the stores mirror the device's settings
    /// into it: it keeps and records each write. Safe for concurrent use.
    final class FakeLocalState: SdkLocalState, @unchecked Sendable {
        private let stateLock = NSLock()
        private var dnsWrites: [DnsSettings] = []
        private var overridesWrites: [[String]] = []
        private var overrides: SdkBlockActionOverrideList?

        override init() {
            super.init(ref: NSObject())
        }

        /// The dns resolver settings mirrored, in order.
        var dnsSettingsWrites: [DnsSettings] {
            stateLock.withLock { dnsWrites }
        }

        /// The split rules mirrored, in order, each as its rules' hosts.
        var splitRuleWrites: [[String]] {
            stateLock.withLock { overridesWrites }
        }

        func forgetWrites() {
            stateLock.withLock {
                dnsWrites = []
                overridesWrites = []
            }
        }

        override func setDnsResolverSettings(_ dnsResolverSettings: SdkDnsResolverSettings?) throws {
            let settings = dnsResolverSettings.map { DnsSettings($0) } ?? DnsSettings()
            stateLock.withLock { dnsWrites.append(settings) }
        }

        override func setBlockActionOverrides(_ blockActionOverrides: SdkBlockActionOverrideList?) throws {
            var hosts: [String] = []
            if let blockActionOverrides {
                for i in 0..<blockActionOverrides.len() {
                    hosts.append(DeviceStoreDeviceCallTests.hosts(blockActionOverrides.get(i)))
                }
            }
            stateLock.withLock {
                overridesWrites.append(hosts)
                overrides = blockActionOverrides
            }
        }

        override func getBlockActionOverrides() -> SdkBlockActionOverrideList? {
            stateLock.withLock { overrides }
        }
    }

    /// dns settings that differ by `servers` remote dns servers
    nonisolated private static func dns(servers: Int) -> DnsSettings {
        var settings = DnsSettings()
        settings.enableRemoteDns = true
        settings.remoteDnsIpv4 = (0..<servers).map { "192.0.2.\($0 + 1)" }
        return settings
    }

    /// A site split rule routing `host` locally.
    nonisolated private static func rule(_ host: String) -> SdkBlockActionOverride {
        let override = SdkBlockActionOverride()
        override.overrideId = SdkNewId()
        let hosts = SdkStringList()
        hosts?.add(host)
        override.hosts = hosts
        override.routeOverride = SplitRuleMode.excluded.toSdkRouteOverride()
        return override
    }

    /// A rule's hosts, joined.
    nonisolated static func hosts(_ override: SdkBlockActionOverride?) -> String {
        guard let list = override?.hosts else {
            return ""
        }
        return (0..<list.len()).map { list.get($0) }.joined(separator: ",")
    }

    /// Returns once what was queued on the main queue so far has run: the
    /// listeners hop there.
    private static func mainQueueDrained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    // MARK: the peers store

    /// Every peers report logged the device's raw peers, in release builds
    /// too: GetNetworkPeers, an rpc under the device's state lock, made on
    /// the main actor. Now the read is debug only and runs on the device work
    /// queue, one for a burst of reports, and the main actor goes on.
    @Test func aPeersReportMakesNoDeviceCallOnTheMainThread() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let store = NetworkPeersStore(deviceWorkQueue: work.queue)
        store.setup(device)
        let controller = try #require(device.controller("openPeerViewController"))
        // setup's own calls stay on the main actor: not the report path
        device.forgetMainThreadCalls()

        controller.listeners.reportAll()
        controller.listeners.reportAll()
        controller.listeners.reportAll()
        await Self.mainQueueDrained()
        #expect(device.mainThreadCalls == [])

        await work.run()
        #expect(device.mainThreadCalls == [])
        #if DEBUG
        #expect(device.callCount("getNetworkPeers") == 1)
        #else
        #expect(device.callCount("getNetworkPeers") == 0)
        #endif
        store.reset()
        await work.run()
    }

    // MARK: the dns store's re-reads

    /// Every dns report re-read the device's settings and its rpc on the
    /// main actor: GetDnsResolverSettings, an rpc under the device's state
    /// lock, and GetRemoteConnected under the same lock. Now the reads run
    /// on the device work queue, coalesced, and apply on the main actor.
    @Test func aDnsReportMakesNoDeviceCallOnTheMainThread() async {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let settings = Self.dns(servers: 1)
        device.dnsResolverSettings = settings.toSdk()
        device.remoteConnected = true
        let localState = FakeLocalState()
        let store = DnsSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: localState)
        device.forgetMainThreadCalls()

        // the settings listener and the remote's
        device.storeListeners.reportAll()
        device.storeListeners.reportAll()
        await Self.mainQueueDrained()
        #expect(device.mainThreadCalls == [])
        #expect(store.settings == nil)

        await work.settle()
        #expect(device.mainThreadCalls == [])
        #expect(store.settings == settings)
        // the setup's read, then one for the reports
        #expect(device.callCount("getDnsResolverSettings") == 2)
        #expect(localState.dnsSettingsWrites == [settings, settings])
        store.reset()
        await work.run()
    }

    /// A report's read in flight as the user edits: it read the device
    /// before the edit, and applied it showed and mirrored the settings the
    /// edit replaced. It is dropped, and the edit's read-back applies.
    @Test func aDnsReadFromBeforeAnEditIsDropped() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let before = Self.dns(servers: 1)
        let edited = Self.dns(servers: 2)
        device.dnsResolverSettings = before.toSdk()
        device.remoteConnected = true
        let localState = FakeLocalState()
        let store = DnsSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: localState)
        await work.settle()
        #expect(store.settings == before)
        localState.forgetWrites()

        device.holdNextRead("getDnsResolverSettings")
        device.forgetMainThreadCalls()
        device.storeListeners.reportAll()
        await Self.mainQueueDrained()
        // made on the main actor, the read would answer there, never held
        try #require(device.mainThreadCalls == [])
        await device.waitUntilReadHeld()

        #expect(store.apply(edited, original: before))
        device.releaseRead()
        await work.settle()
        #expect(store.settings == edited)
        #expect(device.dnsResolverSettings.map { DnsSettings($0) } == edited)
        // only the edit's read-back is mirrored
        #expect(localState.dnsSettingsWrites == [edited])
        store.reset()
        await work.run()
    }

    /// A read queued by a setup that a reset retired before it ran (the
    /// window shown, then hidden again behind a held command) changes
    /// nothing and mirrors nothing.
    @Test func aDnsReadThatAResetRetiredMirrorsNothing() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        device.dnsResolverSettings = Self.dns(servers: 1).toSdk()
        device.remoteConnected = true
        let localState = FakeLocalState()
        let store = DnsSettingsStore(deviceWorkQueue: work.queue)

        store.setup(device, localState: localState)
        try #require(device.mainThreadCalls.filter { $0 == "getDnsResolverSettings" } == [])
        store.reset()
        await work.settle()
        #expect(store.settings == nil)
        #expect(localState.dnsSettingsWrites == [])
    }

    // MARK: the split rule store's re-reads

    /// The same for the split rules: every report re-read the rules
    /// (GetBlockActionOverrides, an rpc) and the rpc on the main actor.
    @Test func aSplitRuleReportMakesNoDeviceCallOnTheMainThread() async {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        device.blockActionOverrides = [Self.rule("a.example")]
        device.remoteConnected = true
        let localState = FakeLocalState()
        let store = BlockActionsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: localState)
        device.forgetMainThreadCalls()

        device.storeListeners.reportAll()
        device.storeListeners.reportAll()
        await Self.mainQueueDrained()
        #expect(device.mainThreadCalls == [])
        #expect(store.splitRules.isEmpty)
        #expect(!store.canCreateRule)

        await work.settle()
        #expect(device.mainThreadCalls == [])
        #expect(store.splitRules.map { $0.hosts } == [["a.example"]])
        #expect(store.canCreateRule)
        #expect(store.authoritativeExcludedApps == [])
        #expect(device.callCount("getBlockActionOverrides") == 2)
        #expect(localState.splitRuleWrites == [["a.example"], ["a.example"]])
        store.reset()
        await work.run()
    }

    /// A report's read in flight as the user adds a rule read the list
    /// without it, and applied it mirrored that list. It is dropped, and the
    /// edit's read-back is mirrored.
    @Test func aSplitRuleReadFromBeforeAnEditIsDropped() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        device.blockActionOverrides = [Self.rule("a.example")]
        device.remoteConnected = true
        let localState = FakeLocalState()
        let store = BlockActionsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: localState)
        await work.settle()
        try #require(store.canCreateRule)
        localState.forgetWrites()

        device.holdNextRead("getBlockActionOverrides")
        device.forgetMainThreadCalls()
        device.storeListeners.reportAll()
        await Self.mainQueueDrained()
        try #require(device.mainThreadCalls == [])
        await device.waitUntilReadHeld()

        store.createRule(hosts: ["b.example"], mode: .excluded)
        device.releaseRead()
        await work.settle()
        #expect(store.splitRules.map { $0.hosts } == [["a.example"], ["b.example"]])
        #expect(localState.splitRuleWrites == [["a.example", "b.example"]])
        store.reset()
        await work.run()
    }

    // MARK: the user's edits

    /// Update in the dns editor ran the device's setter, then its read-back,
    /// on the main actor: with a command held, the main actor froze until it
    /// returned. Now the edit shows at once and its setter and read-back run
    /// on the device work queue. Disconnected, the read-back is the edit the
    /// remote queued, and it is mirrored for the next connect, as before.
    @Test func aDnsEditMakesNoDeviceCallOnTheMainThread() async {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let before = Self.dns(servers: 1)
        let edited = Self.dns(servers: 2)
        device.dnsResolverSettings = before.toSdk()
        let localState = FakeLocalState()
        let store = DnsSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: localState)
        await work.settle()
        #expect(store.settings == before)
        // disconnected, a read is not the extension's: nothing is mirrored
        #expect(localState.dnsSettingsWrites == [])

        work.hold()
        device.forgetMainThreadCalls()
        #expect(store.apply(edited, original: before))
        #expect(device.mainThreadCalls == [])
        #expect(store.settings == edited)

        await work.settle()
        #expect(device.mainThreadCalls == [])
        #expect(device.callCount("setDnsResolverSettings") == 1)
        #expect(store.settings == edited)
        #expect(localState.dnsSettingsWrites == [edited])
        store.reset()
        await work.run()
    }

    /// Saving, editing and removing split rules ran the device's setters on
    /// the main actor. Now each edit shows at once, its setter runs on the
    /// device work queue, in order, and the read-back after the last one is
    /// mirrored.
    @Test func splitRuleEditsMakeNoDeviceCallOnTheMainThread() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        device.blockActionOverrides = [Self.rule("a.example")]
        device.remoteConnected = true
        let localState = FakeLocalState()
        let store = BlockActionsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: localState)
        await work.settle()
        try #require(store.canCreateRule)
        localState.forgetWrites()

        work.hold()
        device.forgetMainThreadCalls()
        store.createRule(hosts: ["b.example"], mode: .excluded)
        #expect(store.splitRules.map { $0.hosts } == [["a.example"], ["b.example"]])
        let a = try #require(store.splitRules.first)
        store.updateRule(id: a.id, hosts: ["c.example"], mode: .included)
        #expect(store.splitRules.map { $0.hosts } == [["c.example"], ["b.example"]])
        #expect(store.splitRules.first?.mode == .included)
        let b = try #require(store.splitRules.last)
        store.removeRule(id: b.id)
        #expect(store.splitRules.map { $0.hosts } == [["c.example"]])
        #expect(device.mainThreadCalls == [])

        await work.settle()
        #expect(device.mainThreadCalls == [])
        #expect(device.callCount("addBlockActionOverride") == 1)
        #expect(device.callCount("setBlockActionOverrides") == 1)
        #expect(device.callCount("removeBlockActionOverride") == 1)
        #expect(device.blockActionOverrides?.map { Self.hosts($0) } == ["c.example"])
        #expect(store.splitRules.map { $0.hosts } == [["c.example"]])
        #expect(localState.splitRuleWrites.last == ["c.example"])
        store.reset()
        await work.run()
    }

    /// Update in the transport editor ran the device's setter on the main
    /// actor. Now the policy shows at once, the setter and the read-back run
    /// on the device work queue, and a report of the policy from before the
    /// setter, still on its way, does not show the replaced policy again.
    @Test func aTransportEditMakesNoDeviceCallOnTheMainThread() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let store = TransportSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: nil)
        // the listeners report the device's policies
        device.storeListeners.reportAll()
        await work.settle()
        let original = try #require(store.settings(.client))

        work.hold()
        device.forgetMainThreadCalls()
        let h1 = try #require(SdkDefaultTransportSettings())
        h1.mode = TransportType.h1.rawValue
        #expect(store.apply(h1, original: original, kind: .client))
        #expect(device.mainThreadCalls == [])
        #expect(store.settings(.client)?.singleTransport == .h1)

        // the fake's listeners report the default policies, auto for the
        // client: from before the setter
        device.storeListeners.reportAll()
        await Self.mainQueueDrained()
        #expect(store.settings(.client)?.singleTransport == .h1)
        // the provider policy has no edit pending: its report shows
        #expect(store.settings(.provider) != nil)

        await work.settle()
        #expect(device.mainThreadCalls == [])
        #expect(device.callCount("setTransportSettings") == 1)
        #expect(store.settings(.client)?.singleTransport == .h1)
        // from here the listener's reports show the policy in force again
        device.storeListeners.reportAll()
        await Self.mainQueueDrained()
        #expect(store.settings(.client)?.isAuto == true)
        store.reset()
        await work.run()
    }

    // MARK: the editors' compare and set

    /// The dns editor opened while the store had no settings (the setup's
    /// read not landed yet, or a reset with the sheet open) started from the
    /// blank form, and its Update replaced the extension's resolver with it.
    /// An apply now compares the settings the editor was seeded from with the
    /// store's, and with none there is nothing to apply from.
    @Test func aDnsEditFromTheBlankFormIsRefused() async {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let settings = Self.dns(servers: 1)
        device.dnsResolverSettings = settings.toSdk()
        let store = DnsSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: nil)
        #expect(store.settings == nil)

        var draft = DnsSettings()
        draft.enableLocalDns = true
        #expect(!store.apply(draft, original: DnsSettings()))
        await work.settle()
        #expect(device.callCount("setDnsResolverSettings") == 0)
        #expect(store.settings == settings)
        store.reset()
        await work.run()
    }

    /// An editor opened before another edit (or a report) moved the store's
    /// settings would replace them whole with its older draft. Refused, it
    /// seeds again; the edit made from the current settings applies.
    @Test func aDnsEditFromSettingsThatMovedIsRefused() async {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let before = Self.dns(servers: 1)
        device.dnsResolverSettings = before.toSdk()
        let store = DnsSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: nil)
        await work.settle()

        #expect(store.apply(Self.dns(servers: 2), original: before))
        #expect(!store.apply(Self.dns(servers: 3), original: before))
        await work.settle()
        #expect(device.callCount("setDnsResolverSettings") == 1)
        #expect(store.settings == Self.dns(servers: 2))
        #expect(store.apply(Self.dns(servers: 3), original: Self.dns(servers: 2)))
        await work.settle()
        #expect(store.settings == Self.dns(servers: 3))
        store.reset()
        await work.run()
    }

    /// The same for the transport editors: with no policy the editor's draft
    /// is the defaults, and an editor opened before the policy moved holds
    /// the older one.
    @Test func aTransportEditFromAMissingOrMovedPolicyIsRefused() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let store = TransportSettingsStore(deviceWorkQueue: work.queue)
        store.setup(device, localState: nil)
        await work.settle()
        #expect(store.settings(.client) == nil)
        let h1 = try #require(SdkDefaultTransportSettings())
        h1.mode = TransportType.h1.rawValue
        #expect(!store.apply(h1, original: TransportSettingsKind.client.defaultSettings, kind: .client))

        device.storeListeners.reportAll()
        await work.settle()
        let original = try #require(store.settings(.client))
        #expect(store.apply(h1, original: original, kind: .client))
        let h3 = try #require(SdkDefaultTransportSettings())
        h3.mode = TransportType.h3.rawValue
        #expect(!store.apply(h3, original: original, kind: .client))
        await work.settle()
        #expect(device.callCount("setTransportSettings") == 1)
        #expect(store.settings(.client)?.singleTransport == .h1)
        store.reset()
        await work.run()
    }

    /// An editor seeded with no settings is disabled, and seeds from the
    /// first settings the store publishes. Later ones leave the user's draft
    /// alone (an apply from it is refused if they moved), and a refused apply
    /// seeds again from the store's settings. While the store has none (a
    /// reset with the sheet open) a seeded editor is disabled too.
    @Test func anEditorWithoutSettingsIsDisabledUntilTheyArrive() {
        var seed = SettingsEditorSeed<DnsSettings>(nil)
        #expect(!seed.editable(with: nil))
        #expect(seed.storeChanged(nil) == nil)
        #expect(!seed.editable(with: nil))

        let first = Self.dns(servers: 1)
        #expect(seed.storeChanged(first) == first)
        #expect(seed.editable(with: first))
        #expect(seed.original == first)
        #expect(seed.storeChanged(Self.dns(servers: 2)) == nil)
        #expect(seed.original == first)

        // the stores reset under the open editor
        #expect(!seed.editable(with: nil))
        #expect(seed.storeChanged(nil) == nil)
        #expect(seed.original == first)

        seed.reseed(Self.dns(servers: 2))
        #expect(seed.original == Self.dns(servers: 2))
        #expect(seed.editable(with: Self.dns(servers: 2)))

        // an editor opened on the store's settings is editable at once
        let opened = SettingsEditorSeed<DnsSettings>(first)
        #expect(opened.editable(with: first))
        #expect(opened.original == first)
        // and one opened on none, never from the blank form
        #expect(!SettingsEditorSeed<DnsSettings>(nil).editable(with: first))
    }
}
