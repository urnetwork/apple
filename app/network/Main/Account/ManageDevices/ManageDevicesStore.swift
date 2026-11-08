//
//  ManageDevicesStore.swift
//  URnetwork
//
//  The device list ("Manage devices"): the network's devices and hosted
//  proxies, each removable, so a user at the client limit frees a slot for
//  this device. Opened from the client limit notice, from a sign-in the limit
//  refused, and from Settings.
//
//  The sdk's ManageDevicesViewController decides everything: what the list
//  holds and its order, the network credential every request carries (never a
//  client token), and adding this device again after a removal (it ends the
//  device's client limit hold, or calls the sign-in's retry). This store only
//  mirrors the controller's snapshots into value types on the main actor,
//  forwards the screen's intents, and holds the confirmation a removal waits
//  for.
//

import Foundation
import URnetworkSdk

/// One device or hosted proxy of the list.
struct ManagedDeviceItem: Equatable, Identifiable {
    /// the client id
    let id: String
    /// a hosted proxy, else a device
    var proxy: Bool = false
    /// the device's name, else its description; may be empty
    var name: String = ""
    /// system and model; may be empty
    var spec: String = ""
    /// the device the app runs on: no Remove
    var thisDevice: Bool = false
    /// connected now, so it takes a slot
    var connected: Bool = false
    /// unix milliseconds of its last sign-in; 0 when unknown
    var lastSeenTime: Int64 = 0
}

/// One read of the controller.
struct ManageDevicesState: Equatable {
    /// this device first, then the connected ones, then the latest seen
    var devices: [ManagedDeviceItem] = []
    var loaded: Bool = false
    var loading: Bool = false
    /// the client a removal is in flight for
    var removingClientId: String? = nil
    /// an SdkManageDevicesError constant; empty after a success
    var errorId: String = ""
    /// the removals that freed a slot and added this device again
    var addRetryCount: Int = 0

    var signInRequired: Bool {
        errorId == SdkManageDevicesErrorSignInRequired
    }

    var loadFailed: Bool {
        errorId == SdkManageDevicesErrorLoadFailed
    }

    var removeFailed: Bool {
        errorId == SdkManageDevicesErrorRemoveFailed
    }
}

@MainActor
final class ManageDevicesStore: ObservableObject {

    @Published private(set) var state = ManageDevicesState()
    /// the removal waiting for the user's answer
    @Published private(set) var confirmation: ManagedDeviceItem? = nil
    /// a removal just added this device again; clears after a few seconds
    @Published private(set) var connecting = false

    private let open: () -> SdkManageDevicesViewController?
    private let release: (SdkManageDevicesViewController) -> Void
    private var controller: SdkManageDevicesViewController?
    private var listenerSub: SdkSubProtocol?
    private var closed = false
    private var connectingWork: DispatchWorkItem?

    init(
        open: @escaping () -> SdkManageDevicesViewController?,
        release: @escaping (SdkManageDevicesViewController) -> Void
    ) {
        self.open = open
        self.release = release
    }

    /// Opened from the signed-in device, which owns the controller: after a
    /// removal it ends this device's client limit hold.
    static func forDevice(_ device: SdkDeviceRemote) -> ManageDevicesStore {
        ManageDevicesStore(
            open: { device.openManageDevicesViewController() },
            release: { device.close($0) }
        )
    }

    /// Opened for a sign-in the client limit refused: there is no device yet,
    /// so every request carries the sign-in's network token, and after a
    /// removal `retry` runs the sign-in again (on the main actor).
    static func forSignIn(api: SdkApi, networkJwt: String, retry: @escaping @MainActor () -> Void) -> ManageDevicesStore {
        ManageDevicesStore(
            open: { SdkNewSignInManageDevicesViewController(api, networkJwt, ManageDevicesSignInRetry(retry)) },
            release: { $0.close() }
        )
    }

    deinit {
        // the screen is gone: listener first, then the controller
        listenerSub?.close()
        if let controller {
            release(controller)
        }
    }

    /// Opens, subscribes to and starts the controller the first time; a later
    /// call reloads the list.
    func start() {
        guard !closed else {
            return
        }
        if let controller {
            controller.refresh()
            return
        }
        guard let controller = open() else {
            return
        }
        self.controller = controller
        listenerSub = controller.add(ManageDevicesListener { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
        })
        controller.start()
        update()
    }

    /// Drops the listener, then closes the controller. Final.
    func close() {
        guard !closed else {
            return
        }
        closed = true
        listenerSub?.close()
        listenerSub = nil
        if let controller {
            release(controller)
        }
        controller = nil
        confirmation = nil
        connectingWork?.cancel()
        connectingWork = nil
    }

    func refresh() {
        guard !closed else {
            return
        }
        controller?.refresh()
    }

    /// A row's Remove: asks first. Never for this device, and not while
    /// another removal runs.
    func requestRemove(_ device: ManagedDeviceItem) {
        guard !closed, !device.thisDevice, state.removingClientId == nil else {
            return
        }
        confirmation = device
    }

    /// The user confirmed the removal the dialog presented.
    func confirmRemove(_ device: ManagedDeviceItem) {
        confirmation = nil
        guard !closed, let controller else {
            return
        }
        var parseError: NSError?
        guard let clientId = SdkParseId(device.id, &parseError), parseError == nil else {
            return
        }
        controller.removeDevice(clientId)
        update()
    }

    func cancelRemove() {
        confirmation = nil
    }

    /// Reads the controller's newest snapshot, not the one a listener was
    /// handed, so a late delivery never replaces a newer one.
    private func update() {
        guard !closed, let controller else {
            return
        }
        let next = ManageDevicesState(controller.getSnapshot())
        if next.addRetryCount > state.addRetryCount {
            showConnecting()
        }
        if next != state {
            state = next
        }
    }

    private func showConnecting() {
        connecting = true
        connectingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.connecting = false
        }
        connectingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }
}

// MARK: SDK

/// The controller's listener, calling a closure on an sdk thread.
private final class ManageDevicesListener: NSObject, SdkManageDevicesListenerProtocol {
    private let callback: @Sendable () -> Void

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func manageDevicesChanged(_ snapshot: SdkManageDevicesSnapshot?) {
        callback()
    }
}

/// The sign-in's retry, called on an sdk thread after a removal freed a slot.
private final class ManageDevicesSignInRetry: NSObject, SdkManageDevicesSignInRetryProtocol {
    private let retry: @MainActor () -> Void

    init(_ retry: @escaping @MainActor () -> Void) {
        self.retry = retry
    }

    func retrySignIn() {
        let retry = self.retry
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                retry()
            }
        }
    }
}

extension ManageDevicesState {

    /// A copy of the sdk's snapshot.
    init(_ snapshot: SdkManageDevicesSnapshot?) {
        self.init()
        guard let snapshot else {
            return
        }
        if let list = snapshot.devices {
            devices.reserveCapacity(list.len())
            for i in 0..<list.len() {
                guard let device = list.get(i), let clientId = device.clientId?.idStr, !clientId.isEmpty else {
                    continue
                }
                devices.append(ManagedDeviceItem(
                    id: clientId,
                    proxy: device.kind == SdkManagedDeviceKindProxy,
                    name: device.name,
                    spec: device.spec,
                    thisDevice: device.thisDevice,
                    connected: device.connected,
                    lastSeenTime: device.lastSeenTime
                ))
            }
        }
        loaded = snapshot.loaded
        loading = snapshot.loading
        removingClientId = snapshot.removingClientId?.idStr
        errorId = snapshot.errorId
        addRetryCount = snapshot.addRetryCount
    }
}
