//
//  ProviderLocationsStore.swift
//  URnetwork
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * One currently connected provider, as rendered by the globe and the list.
 * The SDK returns these sorted oldest-connected first (= descending duration).
 */
struct ProviderLocationRow: Identifiable, Equatable {

    let clientId: SdkId
    let country: String
    let countryCode: String
    let region: String
    let city: String
    // false when the provider's location is unknown: the user's own fixed
    // peers, restored window identities, and older servers
    let hasLocation: Bool
    // the coordinates to plot: the city centroid when known, else the region
    // centroid. nil when the provider has no coordinates at all
    let lat: Double?
    let lon: Double?
    // unix millis; the UI ticks the duration locally against this
    let connectedSinceMillis: Int64

    var id: String {
        clientId.idStr
    }

    var plottable: Bool {
        lat != nil && lon != nil
    }

    // compare by the stable string id — SdkId is an SDK object compared by
    // identity, which differs on every re-read and would defeat the dedup
    static func == (lhs: ProviderLocationRow, rhs: ProviderLocationRow) -> Bool {
        lhs.id == rhs.id
            && lhs.country == rhs.country
            && lhs.countryCode == rhs.countryCode
            && lhs.region == rhs.region
            && lhs.city == rhs.city
            && lhs.hasLocation == rhs.hasLocation
            && lhs.lat == rhs.lat
            && lhs.lon == rhs.lon
            && lhs.connectedSinceMillis == rhs.connectedSinceMillis
    }
}

private class ConnectedProviderLocationsListener: NSObject, SdkConnectedProviderLocationChangeListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func connectedProviderLocationsChanged() {
        callback()
    }
}

private class ProviderLocationsRemoteListener: NSObject, SdkRemoteChangeListenerProtocol {
    private let callback: (Bool) -> Void
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }
    func remoteChanged(_ remoteConnected: Bool) {
        callback(remoteConnected)
    }
}

/**
 * Publishes the currently connected providers and their locations.
 *
 * The SDK change listener carries no payload — it is a signal that the window
 * changed, so every notify re-reads `getConnectedProviderLocations()`. The SDK
 * hands back fresh proxy objects on every read, so the rows are compared by
 * value and only published when something actually changed: the view also runs
 * a one-second duration clock, and republishing an identical list under it
 * would rebuild the globe once a second.
 */
@MainActor
class ProviderLocationsStore: ObservableObject {

    @Published private(set) var rows: [ProviderLocationRow] = []

    /// the row the globe is centered on; kept in sync with the list selection
    @Published var selectedClientId: String? = nil

    // Whether the window state is live. It lives in the network extension's
    // device, and the extension only runs while the tunnel is up: with the RPC
    // down there is nothing real to report, and rendering the empty store as
    // "no providers connected" presents a stale zero as fact. The view shows
    // the disabled-discovery treatment instead while this is false.
    @Published private(set) var providersAvailable: Bool = false

    private var device: SdkDeviceRemote?
    private var locationsSub: SdkSubProtocol?
    private var remoteSub: SdkSubProtocol?

    func setup(_ device: SdkDeviceRemote) {
        reset()

        self.device = device
        self.locationsSub = device.add(ConnectedProviderLocationsListener { [weak self] in
            DispatchQueue.main.async {
                self?.update()
            }
        })
        self.remoteSub = device.add(ProviderLocationsRemoteListener { [weak self] remoteConnected in
            DispatchQueue.main.async {
                self?.providersAvailable = remoteConnected
                if remoteConnected {
                    // the reconnect listener-sync pushes fresh window events;
                    // refresh defensively so a just-enabled view never shows a
                    // stale empty list
                    self?.update()
                }
            }
        })
        // GetRemoteConnected — swift's importer strips the redundant "Remote"
        self.providersAvailable = device.getConnected()
        update()
    }

    func reset() {
        locationsSub?.close()
        locationsSub = nil
        remoteSub?.close()
        remoteSub = nil
        device = nil
        rows = []
        selectedClientId = nil
        providersAvailable = false
    }

    func select(_ clientId: String?) {
        if selectedClientId != clientId {
            selectedClientId = clientId
        }
    }

    /**
     * Drops the provider from the connection and stops it being re-discovered
     * for the rest of this connection. The row disappears when the SDK reports
     * the window change; the local list is trimmed first so the swipe does not
     * appear to snap back while that round trip happens.
     */
    func removeProvider(_ row: ProviderLocationRow) {
        withAnimation(.easeInOut(duration: 0.25)) {
            rows = rows.filter { $0.id != row.id }
        }
        if selectedClientId == row.id {
            selectedClientId = nil
        }
        device?.removeConnectedProvider(row.clientId)
    }

    private func update() {
        var newRows: [ProviderLocationRow] = []
        if let list = device?.getConnectedProviderLocations() {
            for i in 0..<list.len() {
                guard let location = list.get(i), let clientId = location.clientId else {
                    continue
                }
                let lat: Double?
                let lon: Double?
                if location.hasCityCoordinates {
                    lat = location.cityLat
                    lon = location.cityLon
                } else if location.hasRegionCoordinates {
                    lat = location.regionLat
                    lon = location.regionLon
                } else {
                    lat = nil
                    lon = nil
                }
                newRows.append(
                    ProviderLocationRow(
                        clientId: clientId,
                        country: location.country,
                        countryCode: location.countryCode,
                        region: location.region,
                        city: location.city,
                        hasLocation: location.hasLocation,
                        lat: lat,
                        lon: lon,
                        connectedSinceMillis: location.connectedSinceMillis
                    )
                )
            }
        }

        // only publish when the values actually changed
        if newRows != rows {
            withAnimation(.easeInOut(duration: 0.25)) {
                rows = newRows
            }
        }
        // drop a selection whose provider left the window
        if let selected = selectedClientId, !newRows.contains(where: { $0.id == selected }) {
            selectedClientId = nil
        }
    }
}
