//
//  DeviceStores.swift
//  URnetwork
//

import Foundation
import URnetworkSdk

/**
 * The stores that follow the device while the window shows (macOS) or the
 * app is in the foreground (iOS). NetworkApp sets them up with the connect
 * view model and resets them when it suspends or resets it.
 *
 * A reset makes no call on the device on the main actor. On the sdk's
 * DeviceRemote a device sub's close and a controller's close take the
 * device's state lock (the controller's close removes its own listeners from
 * the device), and a connect or disconnect command holds that lock through
 * its rpc to the extension, up to the sdk's 60 s rpc timeout. Made on the
 * main actor, the closes froze it for as long when the window hid with a
 * command in the sdk. They run on the device work queue instead (the connect
 * view model's command queue, see `init(deviceWorkQueue:)`), after the
 * commands queued so far. A controller's own listeners are its callback
 * lists, with no device lock: they close at once.
 *
 * Until its closes have run a store's listeners can still report, and a
 * report already on its way to the main actor arrives after the reset: each
 * store drops the reports of the listeners its reset retired (its
 * generation), after a setup on the next device too.
 *
 * Setup still opens the controllers, adds the listeners and reads the device
 * on the main actor.
 */
@MainActor
struct DeviceStores {
    let throughputStore: ThroughputStore
    let blockActionsStore: BlockActionsStore
    let dnsSettingsStore: DnsSettingsStore
    let transportSettingsStore: TransportSettingsStore
    let networkPeersStore: NetworkPeersStore
    let reliabilityStore: ReliabilityStore
    // this device's provider status from the server, for the provider statistics
    let providerStatusStore: ProviderStatusStore

    /// The stores, closing their device subs and controllers on
    /// `deviceWorkQueue`: NetworkApp passes the connect view model's command
    /// queue, so they close after its commands. The reliability store makes
    /// every device call on its own queue already.
    init(deviceWorkQueue: DispatchQueue) {
        throughputStore = ThroughputStore(deviceWorkQueue: deviceWorkQueue)
        blockActionsStore = BlockActionsStore(deviceWorkQueue: deviceWorkQueue)
        dnsSettingsStore = DnsSettingsStore(deviceWorkQueue: deviceWorkQueue)
        transportSettingsStore = TransportSettingsStore(deviceWorkQueue: deviceWorkQueue)
        networkPeersStore = NetworkPeersStore(deviceWorkQueue: deviceWorkQueue)
        reliabilityStore = ReliabilityStore()
        providerStatusStore = ProviderStatusStore(deviceWorkQueue: deviceWorkQueue)
    }

    /// `localState` is the app's own local state, which mirrors the split
    /// rule, dns and transport settings edits so they survive an app relaunch
    /// while the tunnel is down (see the stores).
    func setup(_ device: SdkDeviceRemote, localState: SdkLocalState?) {
        throughputStore.setup(device)
        blockActionsStore.setup(device, localState: localState)
        dnsSettingsStore.setup(device, localState: localState)
        transportSettingsStore.setup(device, localState: localState)
        networkPeersStore.setup(device)
        reliabilityStore.setup(device)
        providerStatusStore.setup(device)
    }

    func reset() {
        throughputStore.reset()
        blockActionsStore.reset()
        dnsSettingsStore.reset()
        transportSettingsStore.reset()
        networkPeersStore.reset()
        reliabilityStore.reset()
        providerStatusStore.reset()
    }
}

/// A device work queue of its own, for a store made outside DeviceStores
/// (previews, tests): its closes are off the main actor, but not behind the
/// connect commands.
func newDeviceWorkQueue() -> DispatchQueue {
    DispatchQueue(label: "network.ur.device-work", qos: .userInitiated)
}

/// Closes a device's `subs`, then runs `close` (a controller's close), on
/// `queue`, after the work queued there so far. See DeviceStores.
func closeOnDeviceWorkQueue(
    _ queue: DispatchQueue,
    _ subs: [SdkSubProtocol?],
    then close: (@Sendable () -> Void)? = nil
) {
    let work = DeviceCloseWork(subs: subs.compactMap { $0 }, close: close)
    if work.subs.isEmpty && close == nil {
        return
    }
    queue.async {
        work.run()
    }
}

/// Handed from the main actor to the device work queue, where `run` is
/// called once. Unchecked: the sdk's subs are gomobile proxies that may be
/// called from any thread, and nothing here changes after the hand off.
private struct DeviceCloseWork: @unchecked Sendable {
    let subs: [SdkSubProtocol]
    let close: (@Sendable () -> Void)?

    func run() {
        for sub in subs {
            sub.close()
        }
        close?()
    }
}
