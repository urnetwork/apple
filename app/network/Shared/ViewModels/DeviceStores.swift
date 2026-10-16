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
 * A report makes no device call on the main actor either. The dns and split
 * rule stores re-read the device on every report: the reads run on the
 * device work queue (DeviceReads, readOnDeviceWorkQueue) and apply on the
 * main actor. The peer store's raw log reads there too, and the editors'
 * setters run there.
 *
 * Setup still opens the controllers, adds the listeners and reads the device
 * on the main actor, but only once the connect commands queued so far have
 * run (DeferredWindowSetup), so no command holds the lock then, unless taps
 * kept queuing commands through every wait it allows.
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

/**
 * What a settings editor (dns, transport) edits from: the store's settings
 * it was seeded with (`original`), nil while the store had none. Main actor
 * only, like the editor's state.
 *
 * The editor is disabled while it has no original or the store has no
 * settings (`editable`): its draft would start from the blank form or the
 * defaults, not the device's settings, and an edit applied from there
 * replaces the device's settings whole on the next connect (the extension's
 * resolver, its transport policy). The store's settings are nil until the
 * setup's first read lands, and after every reset (the window hidden, the
 * app backgrounded), while a sheet can still be open; the draft stays the
 * user's meanwhile. The editor seeds from the first settings the store
 * publishes, and again after the store refused an apply (compare and set:
 * the store's settings moved since the seed).
 */
struct SettingsEditorSeed<Settings: Equatable>: Equatable {
    private(set) var original: Settings?

    init(_ settings: Settings?) {
        original = settings
    }

    /// Whether the editor can edit and apply, with the store's `settings`.
    func editable(with settings: Settings?) -> Bool {
        original != nil && settings != nil
    }

    /// The store published `settings`: the first ones seed the editor and are
    /// returned, for its draft. Later ones leave the user's draft alone; an
    /// apply from it is refused if they moved.
    mutating func storeChanged(_ settings: Settings?) -> Settings? {
        guard original == nil, let settings else {
            return nil
        }
        original = settings
        return settings
    }

    /// The store refused the apply: the editor starts over from `settings`,
    /// the store's now.
    mutating func reseed(_ settings: Settings) {
        original = settings
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

/// Runs `read` on `queue`, after the work queued there so far, then `apply`
/// with its answer on the main actor. The answers apply in the order the
/// reads were queued. See DeviceStores.
func readOnDeviceWorkQueue<Value>(
    _ queue: DispatchQueue,
    _ read: @escaping () -> Value,
    then apply: @escaping @MainActor (Value) -> Void
) {
    let work = DeviceReadWork(read: read, apply: apply)
    queue.async {
        work.run()
    }
}

/// A read handed to the device work queue and its answer handed back.
/// Unchecked, as DeviceCloseWork: `read` calls the sdk's gomobile proxies,
/// which may be called from any thread, its answer is an sdk value no one
/// else holds, and `apply` runs only on the main actor.
private struct DeviceReadWork<Value>: @unchecked Sendable {
    let read: () -> Value
    let apply: @MainActor (Value) -> Void

    func run() {
        let answer = DeviceReadAnswer(value: read(), apply: apply)
        DispatchQueue.main.async {
            answer.run()
        }
    }
}

private struct DeviceReadAnswer<Value>: @unchecked Sendable {
    let value: Value
    let apply: @MainActor (Value) -> Void

    @MainActor
    func run() {
        apply(value)
    }
}

/**
 * A store's re-reads of the device on the device work queue (DeviceStores):
 * which read to queue, and whether its answer applies when it lands on the
 * main actor. Main actor only, like the store that owns it.
 *
 * One read is queued at a time. A request made while one is queued wants
 * another, queued once the first has landed, so it runs after everything the
 * request followed (`request`, `landed`).
 *
 * Edits and applied reads advance the revision. A read applies only when the
 * revision is the one it was queued at: one queued before an edit read the
 * device before the edit's setter ran, which is older than what the store
 * shows, and above all it must not write the store's mirror of the device's
 * settings. The store's generation retires the reads of a reset on top.
 *
 * A read requested by an edit is its read-back (`afterEdit`): the store
 * mirrors it whatever the device's rpc, as it did when the read ran right
 * after the setter on the main actor. A read wanted after an edit stays one.
 */
struct DeviceReads {
    struct Read: Equatable {
        let revision: Int
        let afterEdit: Bool
    }

    private(set) var revision = 0
    private var reading = false
    private var wanted = false
    private var wantedAfterEdit = false

    /// An edit was made: the reads queued before it are older than it.
    mutating func edited() {
        revision += 1
    }

    /// The read to queue now, or nil when one is queued already: one more
    /// is queued when it lands.
    mutating func request(afterEdit: Bool = false) -> Read? {
        wantedAfterEdit = wantedAfterEdit || afterEdit
        if reading {
            wanted = true
            return nil
        }
        reading = true
        let read = Read(revision: revision, afterEdit: wantedAfterEdit)
        wantedAfterEdit = false
        return read
    }

    /// `read` landed: whether it applies, which advances the revision, and
    /// whether to request another.
    mutating func landed(_ read: Read) -> (applies: Bool, again: Bool) {
        reading = false
        let applies = read.revision == revision
        if applies {
            revision += 1
        }
        let again = wanted
        wanted = false
        return (applies: applies, again: again)
    }

    /// A reset: the reads queued so far land in a retired generation and are
    /// never landed.
    mutating func reset() {
        reading = false
        wanted = false
        wantedAfterEdit = false
    }
}
