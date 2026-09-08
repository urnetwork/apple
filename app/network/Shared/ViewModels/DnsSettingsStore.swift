//
//  DnsSettingsStore.swift
//  URnetwork
//
//  Created by Brien Colwell on 7/8/26.
//

import Foundation
import SwiftUI
import URnetworkSdk

/**
 * Editable snapshot of the device dns resolver settings
 */
struct DnsSettings: Equatable {
    var enableRemoteDoh: Bool = false
    var enableLocalDoh: Bool = false
    var enableRemoteDns: Bool = false
    var enableLocalDns: Bool = false
    var enableFallback: Bool = false

    var remoteDohUrlsIpv4: [String] = []
    var remoteDohUrlsIpv6: [String] = []
    var localDohUrlsIpv4: [String] = []
    var localDohUrlsIpv6: [String] = []
    var remoteDnsIpv4: [String] = []
    var remoteDnsIpv6: [String] = []
    var localDnsIpv4: [String] = []
    var localDnsIpv6: [String] = []

    /**
     * summary states shown in the connect drawer
     */
    var dohEnabled: Bool {
        enableRemoteDoh || enableLocalDoh
    }
    var unencryptedDnsEnabled: Bool {
        enableRemoteDns || enableLocalDns
    }
    var localDnsEnabled: Bool {
        enableLocalDoh || enableLocalDns
    }
    var localDnsFallbackEnabled: Bool {
        enableFallback
    }

    init() {}

    init(_ settings: SdkDnsResolverSettings) {
        enableRemoteDoh = settings.enableRemoteDoh
        enableLocalDoh = settings.enableLocalDoh
        enableRemoteDns = settings.enableRemoteDns
        enableLocalDns = settings.enableLocalDns
        enableFallback = settings.enableFallback

        remoteDohUrlsIpv4 = Self.stringListToArray(settings.remoteDohUrlsIpv4)
        remoteDohUrlsIpv6 = Self.stringListToArray(settings.remoteDohUrlsIpv6)
        localDohUrlsIpv4 = Self.stringListToArray(settings.localDohUrlsIpv4)
        localDohUrlsIpv6 = Self.stringListToArray(settings.localDohUrlsIpv6)
        remoteDnsIpv4 = Self.stringListToArray(settings.remoteDnsIpv4)
        remoteDnsIpv6 = Self.stringListToArray(settings.remoteDnsIpv6)
        localDnsIpv4 = Self.stringListToArray(settings.localDnsIpv4)
        localDnsIpv6 = Self.stringListToArray(settings.localDnsIpv6)
    }

    func toSdk() -> SdkDnsResolverSettings {
        let settings = SdkDnsResolverSettings()
        settings.enableRemoteDoh = enableRemoteDoh
        settings.enableLocalDoh = enableLocalDoh
        settings.enableRemoteDns = enableRemoteDns
        settings.enableLocalDns = enableLocalDns
        settings.enableFallback = enableFallback

        settings.remoteDohUrlsIpv4 = Self.arrayToStringList(remoteDohUrlsIpv4)
        settings.remoteDohUrlsIpv6 = Self.arrayToStringList(remoteDohUrlsIpv6)
        settings.localDohUrlsIpv4 = Self.arrayToStringList(localDohUrlsIpv4)
        settings.localDohUrlsIpv6 = Self.arrayToStringList(localDohUrlsIpv6)
        settings.remoteDnsIpv4 = Self.arrayToStringList(remoteDnsIpv4)
        settings.remoteDnsIpv6 = Self.arrayToStringList(remoteDnsIpv6)
        settings.localDnsIpv4 = Self.arrayToStringList(localDnsIpv4)
        settings.localDnsIpv6 = Self.arrayToStringList(localDnsIpv6)
        return settings
    }

    private static func stringListToArray(_ list: SdkStringList?) -> [String] {
        guard let list = list else {
            return []
        }
        var values: [String] = []
        values.reserveCapacity(list.len())
        for i in 0..<list.len() {
            values.append(list.get(i))
        }
        return values
    }

    private static func arrayToStringList(_ values: [String]) -> SdkStringList? {
        let list = SdkStringList()
        for value in values {
            list?.add(value)
        }
        return list
    }
}

private class DnsResolverSettingsListener: NSObject, SdkDnsResolverSettingsChangeListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func dnsResolverSettingsChanged(_ dnsResolverSettings: SdkDnsResolverSettings?) {
        callback()
    }
}

private class DnsSettingsRemoteListener: NSObject, SdkRemoteChangeListenerProtocol {
    private let callback: (Bool) -> Void
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }
    func remoteChanged(_ remoteConnected: Bool) {
        callback(remoteConnected)
    }
}

/**
 * Publishes the device dns resolver settings and applies edits.
 *
 * The device persists the settings in its own local state, but in the network
 * extension's container, which the app process cannot read. The store mirrors
 * every reading it can vouch for into the app's own local state, and
 * `DeviceManager.initDevice` seeds the next device from that mirror. Without
 * it the editor opens on the blank never-configured form whenever the tunnel
 * is down -- and an edit applied from that blank base is not merely lost with
 * the app process, it replaces the resolver the extension still holds on the
 * next connect.
 */
@MainActor
class DnsSettingsStore: ObservableObject {

    @Published private(set) var settings: DnsSettings? = nil

    private var device: SdkDeviceRemote?
    // the app's own store, which the resolver settings are mirrored into; the
    // extension keeps its copy in a container this process cannot read
    private var localState: SdkLocalState?
    private var settingsSub: SdkSubProtocol?
    private var remoteSub: SdkSubProtocol?

    func setup(_ device: SdkDeviceRemote, localState: SdkLocalState?) {
        reset()

        self.device = device
        self.localState = localState
        self.settingsSub = device.add(DnsResolverSettingsListener { [weak self] in
            DispatchQueue.main.async {
                self?.update()
            }
        })
        // the settings the extension replays on connect arrive over the
        // reverse sync, which runs before the remote publishes its service, so
        // that read still comes out of the remote's own memory. Re-read once
        // the rpc is up so the mirror is written from the extension's resolver
        // rather than from this process's guess at it
        self.remoteSub = device.add(DnsSettingsRemoteListener { [weak self] remoteConnected in
            DispatchQueue.main.async {
                if remoteConnected {
                    self?.update()
                }
            }
        })

        update()
    }

    func reset() {
        settingsSub?.close()
        settingsSub = nil
        remoteSub?.close()
        remoteSub = nil
        device = nil
        // nothing is persisted from here: reset runs on every backgrounding
        // and the mirror is already current by then
        localState = nil
        settings = nil
    }

    /**
     * Re-reads the settings from the device and, when the read is one this
     * process can vouch for, mirrors it.
     *
     * Only two reads qualify: one taken off a connected device, which is the
     * extension's own resolver, and one taken right after an edit made here.
     * With the rpc down and nothing seeded the device answers out of its own
     * empty memory instead, and mirroring that would replace the app's only
     * durable copy with settings it never read.
     *
     * The mirror is written from the read-back and never from the value just
     * pushed: `DeviceLocal.SetDnsResolverSettings` returns without persisting
     * when the settings are nil or the mux is disabled, so the app cannot take
     * its own write as accepted. Connected, the read-back is the extension's
     * answer to the edit -- a dropped edit mirrors as the settings still in
     * force; disconnected, it is the edit the remote queued, which is what the
     * next connect applies.
     *
     * `getConnected()` is GetRemoteConnected; swift's importer strips the
     * redundant "Remote".
     */
    private func update(afterEdit: Bool = false) {
        guard let device = self.device else {
            return
        }
        if let sdkSettings = device.getDnsResolverSettings() {
            settings = DnsSettings(sdkSettings)
            if afterEdit || device.getConnected() {
                persist(sdkSettings)
            }
        } else {
            settings = nil
        }
    }

    /**
     * Writes the settings to the app's own local state.
     *
     * Always the sdk object read back from the device rather than the
     * `DnsSettings` projection, so the fields this app does not model (the
     * upgrade mask address) survive the mirror.
     *
     * nil is never written: it takes the store's delete branch, and a deleted
     * store reads back as never configured, which is what
     * `DeviceManager.initDevice` reads as "leave the extension's resolver
     * alone". A device that reports no settings therefore mirrors nothing,
     * while settings with everything turned off are a real value -- the user
     * emptied the form -- and are mirrored as one.
     */
    private func persist(_ sdkSettings: SdkDnsResolverSettings) {
        do {
            try localState?.setDnsResolverSettings(sdkSettings)
        } catch {
            print("[DnsSettingsStore]failed to persist dns resolver settings: \(error.localizedDescription)")
        }
    }

    func apply(_ newSettings: DnsSettings) {
        guard let device = self.device else {
            return
        }
        device.setDnsResolverSettings(newSettings.toSdk())
        update(afterEdit: true)
    }
}
