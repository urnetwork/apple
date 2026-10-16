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
    /// command queue. Release it once at least: a queue released while held
    /// crashes.
    final class HeldDeviceWork {
        let queue = DispatchQueue(label: "network.ur.test.device-store-work")
        private var held = true

        init() {
            queue.suspend()
        }

        /// Lets the queued work run, and what is queued later.
        func release() {
            if held {
                held = false
                queue.resume()
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

        store.apply(edited)
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
}
