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
    #if DEBUG
    // debug-only observation timer: logs the raw peer state so a silent
    // no-push session is visible in the console. Log-only — the published
    // list stays purely listener-driven.
    private var debugLogTimer: Timer?
    #endif

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        // the SDK peer view controller already filters to connected + provide-enabled peers
        let vc = device.openPeerViewController()
        self.peerViewController = vc
        self.peersSub = vc?.add(PeersListener { [weak self] in
            DispatchQueue.main.async {
                self?.update()
            }
        })
        self.remoteSub = device.add(RemotePresenceListener { [weak self] remoteConnected in
            DispatchQueue.main.async {
                self?.peersAvailable = remoteConnected
                if remoteConnected {
                    // the reconnect listener-sync pushes fresh peers; refresh
                    // defensively so a just-enabled line never shows a stale zero
                    self?.update()
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

    func reset() {
        peersSub?.close()
        peersSub = nil
        remoteSub?.close()
        remoteSub = nil
        peersAvailable = false
        if let peerViewController {
            if let device {
                device.close(peerViewController)
            } else {
                peerViewController.close()
            }
        }
        peerViewController = nil
        device = nil
        connectedProvidePeers = []
        connectedCount = 0
        #if DEBUG
        debugLogTimer?.invalidate()
        debugLogTimer = nil
        #endif
    }

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

    // debug: dump the RAW device peer state next to the filtered set, to
    // discriminate "no peer frames reach this device" (raw nil/empty) from
    // "peers arrive but are filtered" (raw connected without provide) from
    // "peer marked disconnected" (disconnectedCount > 0)
    private func logRawPeers(filteredCount: Int) {
        guard let device = self.device else {
            print("[peers] update: no device")
            return
        }
        guard let raw = device.getNetworkPeers() else {
            print("[peers] raw=nil (no provider or rpc unavailable) filtered=\(filteredCount)")
            return
        }
        var entries: [String] = []
        if let connected = raw.connected {
            for i in 0..<connected.len() {
                guard let peer = connected.get(i) else { continue }
                let id = peer.clientId?.idStr.prefix(8) ?? "?"
                entries.append("\(id):\(peer.deviceName.isEmpty ? peer.deviceSpec : peer.deviceName):provide=\(peer.provideEnabled)")
            }
        }
        print("[peers] raw connected=\(entries.count) [\(entries.joined(separator: ", "))] disconnected=\(raw.disconnectedCount) filtered=\(filteredCount)")
    }
}
