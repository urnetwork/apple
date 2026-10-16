//
//  NetworkPeersStore.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * A connected peer of this device on the network
 */
struct NetworkPeerItem: Identifiable, Equatable {
    let clientId: SdkId
    let deviceName: String
    let deviceSpec: String
    let provideEnabled: Bool

    var id: String {
        clientId.idStr
    }

    // Stable per-peer UI automation identity. Acceptance selects the exact
    // runner-created provider rather than whichever peer happens to render first.
    var acceptanceIdentifier: String {
        "acceptance.peer.\(clientId.idStr)"
    }

    // compare by the stable string id — SdkId is an SDK object compared by
    // identity, which differs on every rebuild and would defeat the dedup
    static func == (lhs: NetworkPeerItem, rhs: NetworkPeerItem) -> Bool {
        lhs.id == rhs.id
            && lhs.deviceName == rhs.deviceName
            && lhs.deviceSpec == rhs.deviceSpec
            && lhs.provideEnabled == rhs.provideEnabled
    }

    /**
     * the device name, or the device spec if the name is not available
     */
    var displayName: String {
        if !deviceName.isEmpty {
            return deviceName
        }
        if !deviceSpec.isEmpty {
            return deviceSpec
        }
        return clientId.idStr
    }

    /**
     * a direct connection to this peer device
     */
    func toConnectLocation() -> SdkConnectLocation {
        let location = SdkConnectLocation()
        let locationId = SdkConnectLocationId()
        locationId.clientId = clientId
        location.connectLocationId = locationId
        location.name = displayName
        // one of the user's own devices from the peer list — a trusted same-network
        // peer, so the connection egresses under Network provide mode
        location.networkPeer = true
        return location
    }
}

private class PeersListener: NSObject, SdkPeersListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func peersChanged(_ peers: SdkNetworkPeerList?) {
        callback()
    }
}

private class RemotePresenceListener: NSObject, SdkRemoteChangeListenerProtocol {
    private let callback: (Bool) -> Void
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }
    func remoteChanged(_ remoteConnected: Bool) {
        callback(remoteConnected)
    }
}

/**
 * Publishes the connected network peers with provide enabled.
 *
 * Uses the change listener plus one initial get — no polling. Devices
 * without a provider have no network peers and the list stays empty.
 */
@MainActor
class NetworkPeersStore: ObservableObject {

    @Published private(set) var connectedProvidePeers: [NetworkPeerItem] = []

    // ALL connected peers, whether or not they provide — the "You have {n}
    // other devices online" count. Connecting to a peer still requires
    // provide, which is what the filtered list above captures.
    @Published private(set) var connectedCount: Int = 0

    // Whether the peer state is live. The peers state lives in the network
    // extension's device, and the extension only runs while the tunnel is up:
    // with the RPC down there is nothing real to report, and rendering the
    // empty store as "0 other devices online" presents a stale zero as fact.
    // The UI shows a disabled-discovery state instead while this is false.
    @Published private(set) var peersAvailable: Bool = false

    private var device: SdkDeviceRemote?
    private var peerViewController: SdkPeerViewController?
    private var peersSub: SdkSubProtocol?
    private var remoteSub: SdkSubProtocol?
    // the device's sub and the controller close here, off the main actor
    // (DeviceStores)
    private let deviceWorkQueue: DispatchQueue
    // advanced by every reset: a report from a retired listener changes
    // nothing, after the next setup too
    private var generation = 0
    #if DEBUG
    // debug-only observation timer: logs the raw peer state so a silent
    // no-push session is visible in the console. Log-only — the published
    // list stays purely listener-driven.
    private var debugLogTimer: Timer?
    // a raw read is queued on the device work queue and has not logged yet:
    // the reports meanwhile queue no more
    private var rawPeersLogQueued = false
    #endif

    init(deviceWorkQueue: DispatchQueue = newDeviceWorkQueue()) {
        self.deviceWorkQueue = deviceWorkQueue
    }

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        let generation = self.generation
        // the SDK peer view controller already filters to connected + provide-enabled peers
        let vc = device.openPeerViewController()
        self.peerViewController = vc
        self.peersSub = vc?.add(PeersListener { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                self.update()
            }
        })
        self.remoteSub = device.add(RemotePresenceListener { [weak self] remoteConnected in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                if self.peersAvailable != remoteConnected {
                    self.peersAvailable = remoteConnected
                }
                if remoteConnected {
                    // the reconnect listener-sync pushes fresh peers; refresh
                    // defensively so a just-enabled line never shows a stale zero
                    self.update()
                }
            }
        })
        // GetRemoteConnected — swift's importer strips the redundant "Remote"
        self.peersAvailable = device.getConnected()
        vc?.start()
        #if DEBUG
        debugLogTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.logRawPeers(filteredCount: self?.connectedProvidePeers.count ?? 0)
            }
        }
        #endif
    }

    /// Makes no call on the device: its sub and the controller's close,
    /// which removes the controller's listener from the device, take the
    /// device's state lock and run on the device work queue (DeviceStores).
    func reset() {
        generation += 1
        // the controller's own listener
        peersSub?.close()
        peersSub = nil
        peersAvailable = false
        let device = self.device
        let peerViewController = self.peerViewController
        closeOnDeviceWorkQueue(deviceWorkQueue, [remoteSub]) {
            if let peerViewController {
                if let device {
                    device.close(peerViewController)
                } else {
                    peerViewController.close()
                }
            }
        }
        remoteSub = nil
        self.peerViewController = nil
        self.device = nil
        connectedProvidePeers = []
        connectedCount = 0
        #if DEBUG
        debugLogTimer?.invalidate()
        debugLogTimer = nil
        rawPeersLogQueued = false
        #endif
    }

    /// Reads the controller, whose getters take only its own lock, and logs
    /// the device's raw peers (debug builds, off the main actor).
    private func update() {
        guard let vc = self.peerViewController else {
            return
        }
        var peers: [NetworkPeerItem] = []
        if let connected = vc.getPeers() {
            for i in 0..<connected.len() {
                guard let peer = connected.get(i), let clientId = peer.clientId else {
                    continue
                }
                peers.append(
                    NetworkPeerItem(
                        clientId: clientId,
                        deviceName: peer.deviceName,
                        deviceSpec: peer.deviceSpec,
                        provideEnabled: peer.provideEnabled
                    )
                )
            }
        }
        logRawPeers(filteredCount: peers.count)
        // only publish when the values actually changed
        if peers != connectedProvidePeers {
            connectedProvidePeers = peers
        }
        let count = vc.getConnectedCount()
        if count != connectedCount {
            connectedCount = count
        }
    }

    /**
     * Debug builds only: dumps the RAW device peer state next to the filtered
     * set, to discriminate "no peer frames reach this device" (raw nil/empty)
     * from "peers arrive but are filtered" (raw connected without provide)
     * from "peer marked disconnected" (disconnectedCount > 0).
     *
     * The raw read is the device's GetNetworkPeers, an rpc to the extension
     * under the device's state lock, which a connect or disconnect command
     * holds through its own rpc, up to the sdk's 60 s rpc timeout. Made on the
     * main actor on every peers report, in release builds too, it froze the
     * main actor for as long. It runs on the device work queue instead, and
     * nothing waits for it: one is queued at a time, and the reports
     * meanwhile log nothing more.
     */
    private func logRawPeers(filteredCount: Int) {
        #if DEBUG
        guard let device = self.device else {
            print("[peers] update: no device")
            return
        }
        if rawPeersLogQueued {
            return
        }
        rawPeersLogQueued = true
        let generation = self.generation
        let read = NetworkPeersReadWork(device: device)
        deviceWorkQueue.async { [weak self] in
            let line = read.run(filteredCount: filteredCount)
            print(line)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                self.rawPeersLogQueued = false
            }
        }
        #endif
    }
}

#if DEBUG
/// The device's raw peers, read on the device work queue for the debug log.
/// Unchecked: the device is a gomobile proxy that may be called from any
/// thread, and nothing here changes after the hand off.
private struct NetworkPeersReadWork: @unchecked Sendable {
    let device: SdkDeviceRemote

    func run(filteredCount: Int) -> String {
        guard let raw = device.getNetworkPeers() else {
            return "[peers] raw=nil (no provider or rpc unavailable) filtered=\(filteredCount)"
        }
        var entries: [String] = []
        if let connected = raw.connected {
            for i in 0..<connected.len() {
                guard let peer = connected.get(i) else { continue }
                let id = peer.clientId?.idStr.prefix(8) ?? "?"
                entries.append("\(id):\(peer.deviceName.isEmpty ? peer.deviceSpec : peer.deviceName):provide=\(peer.provideEnabled)")
            }
        }
        return "[peers] raw connected=\(entries.count) [\(entries.joined(separator: ", "))] disconnected=\(raw.disconnectedCount) filtered=\(filteredCount)"
    }
}
#endif
