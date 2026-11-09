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
 * Editable snapshot of the device dns resolver settings: the selection
 * (connect ADBLOCK3RD E1) and the lists in force for it, as the device reads
 * them back.
 *
 * A projection: no save builds the sdk settings from it alone. Every save
 * starts from the sdk settings read back from the device, through the sdk's
 * helpers (`DnsResolverSettingsWithPreset`, `DnsResolverSettingsWithFallback`,
 * `DnsResolverSettingsAsCustom`), so the fields this app does not model, the
 * upgrade mask and any a later sdk adds, survive it (E3).
 */
struct DnsSettings: Equatable {
    /// the selection: "default" (URnetwork's dns), a preset id,
    /// "regional-<cc>", or empty for custom settings, the lists below
    var presetId: String = ""
    /// a personal preset's configuration id, else empty. Never shown or
    /// logged (ADBLOCK3RD D5)
    var presetPersonalId: String = ""

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
    /**
     * the opt-in host-network fallback ("Fast DNS on connect"), off unless the
     * user turns it on: it answers dns over the local network while the
     * tunnel's dns starts, which can reveal lookups to the local network and
     * return answers that don't match the exit location
     */
    var fastDnsOnConnectEnabled: Bool {
        enableFallback
    }

    init() {}

    init(_ settings: SdkDnsResolverSettings) {
        presetId = settings.presetId
        presetPersonalId = settings.presetPersonalId
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

    /// This value as custom settings, the custom editor's save (ADBLOCK3RD
    /// E2): `base` as custom settings (`DnsResolverSettingsAsCustom`: the
    /// selection cleared, every other field kept), with this value's resolver
    /// toggles, Fast DNS on connect and lists. The editor saved a fresh sdk
    /// object before, which dropped every field it does not model. A nil
    /// base starts from the defaults.
    func toCustomSdk(base: SdkDnsResolverSettings?) -> SdkDnsResolverSettings? {
        guard let settings = SdkDnsResolverSettingsAsCustom(base) else {
            return nil
        }
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

    /// Whether `other` is this value but for Fast DNS on connect, which the
    /// dns screen's own toggle changes.
    func equalsIgnoringFastDns(_ other: DnsSettings) -> Bool {
        var settings = self
        settings.enableFallback = other.enableFallback
        return settings == other
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

/**
 * The description under the Fast DNS on connect toggle. Its English text is the
 * key of fast_dns_on_connect_description in Localizable.xcstrings, so it must
 * match the localizations store source exactly or the translations are lost.
 */
enum FastDnsOnConnectCopy {
    static let description: LocalizedStringResource = "Answers DNS over the local network while the tunnel's DNS starts. This can reveal your lookups to the local network and return answers that don't match your exit location. When off, DNS only resolves through the tunnel."
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

/// Reports a change of the dns resolver status: its state, its verification
/// or the selection it describes. Not the blocked count, which changes
/// without a report.
private class DnsResolverStatusListener: NSObject, SdkDnsResolverStatusChangeListenerProtocol {
    private let callback: () -> Void
    init(callback: @escaping () -> Void) {
        self.callback = callback
    }
    func dnsResolverStatusChanged(_ dnsResolverStatus: SdkDnsResolverStatus?) {
        callback()
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
 *
 * The edits are the third-party dns presets' (connect ADBLOCK3RD F1, F2): a
 * pick selected in one tap, Fast DNS on connect, and the custom editor's
 * lists. Each starts from the sdk settings last read back, or last pushed,
 * through the sdk's helpers, never from a fresh sdk object, so the selection
 * and every field this app does not model survive it (E3). The store also
 * publishes the device's dns resolver status and, while the dns screen shows
 * it, this connection's blocked-lookups count (C5, C6, I3). What the screen
 * shows of them is the sdk's to describe (`DescribeDnsResolverSettings`,
 * `DescribeDnsResolverStatus`).
 */
@MainActor
class DnsSettingsStore: ObservableObject {

    /// How often the dns screen re-reads the blocked count while it shows
    /// it: the status listener does not report the count (ADBLOCK3RD I3).
    static let blockedCountRefreshInterval: TimeInterval = 5

    @Published private(set) var settings: DnsSettings? = nil
    /// The device's dns resolver status (ADBLOCK3RD C5, C6), nil until the
    /// first read lands.
    @Published private(set) var status: SdkDnsResolverStatus? = nil
    /// This connection's blocked-lookups count (I3), as last read: with the
    /// status, and while the dns screen shows it every
    /// `blockedCountRefreshInterval`.
    @Published private(set) var blockedCount: Int64 = 0

    private var device: SdkDeviceRemote?
    // the sdk settings `settings` projects, read back from the device or just
    // pushed to it: every edit starts from them through the sdk's helpers
    private var sdkSettings: SdkDnsResolverSettings?
    // the app's own store, which the resolver settings are mirrored into; the
    // extension keeps its copy in a container this process cannot read
    private var localState: SdkLocalState?
    private var settingsSub: SdkSubProtocol?
    private var remoteSub: SdkSubProtocol?
    private var statusSub: SdkSubProtocol?
    // the device's subs close here, off the main actor (DeviceStores)
    private let deviceWorkQueue: DispatchQueue
    // advanced by every reset: a report from a retired listener changes
    // nothing, and above all mirrors nothing, after the next setup too
    private var generation = 0
    // the re-reads on the device work queue, and whether one applies
    private var reads = DeviceReads()
    // the same for the status
    private var statusReads = DeviceReads()
    // the dns screen shows the blocked count, and a read of it is queued
    private var blockedCountShown = false
    private var blockedCountReadQueued = false
    private var blockedCountTimer: Timer?

    init(deviceWorkQueue: DispatchQueue = newDeviceWorkQueue()) {
        self.deviceWorkQueue = deviceWorkQueue
    }

    func setup(_ device: SdkDeviceRemote, localState: SdkLocalState?) {
        reset()

        self.device = device
        self.localState = localState
        let generation = self.generation
        self.settingsSub = device.add(DnsResolverSettingsListener { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                self.update()
            }
        })
        // the settings the extension replays on connect arrive over the
        // reverse sync, which runs before the remote publishes its service, so
        // that read still comes out of the remote's own memory. Re-read once
        // the rpc is up so the mirror is written from the extension's resolver
        // rather than from this process's guess at it
        self.remoteSub = device.add(DnsSettingsRemoteListener { [weak self] remoteConnected in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                if remoteConnected {
                    self.update()
                    self.updateStatus()
                }
            }
        })
        // the status reports its state, its verification and the selection
        // it describes; each report is read again, as the settings are
        self.statusSub = device.add(DnsResolverStatusListener { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    return
                }
                self.updateStatus()
            }
        })

        update()
        updateStatus()
        updateBlockedCountTimer()
    }

    /// Makes no call on the device: its subs take the device's state lock
    /// and close on the device work queue (DeviceStores).
    func reset() {
        generation += 1
        reads.reset()
        statusReads.reset()
        closeOnDeviceWorkQueue(deviceWorkQueue, [settingsSub, remoteSub, statusSub])
        settingsSub = nil
        remoteSub = nil
        statusSub = nil
        device = nil
        // nothing is persisted from here: reset runs on every backgrounding
        // and the mirror is already current by then
        localState = nil
        settings = nil
        sdkSettings = nil
        status = nil
        blockedCount = 0
        // the dns screen's visibility stays: the next setup reads again
        blockedCountReadQueued = false
        blockedCountTimer?.invalidate()
        blockedCountTimer = nil
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
     * The read runs on the device work queue, never on the main actor: the
     * getters take the device's state lock, which a connect or disconnect
     * command holds through its rpc, up to the sdk's 60 s rpc timeout, and
     * every report re-read on the main actor froze it for as long. It applies
     * on the main actor only while the generation and the revision are the
     * ones it was queued at (DeviceReads): a read from before an edit, or
     * from a retired listener, neither shows nor mirrors.
     */
    private func update(afterEdit: Bool = false) {
        guard let device = self.device, let read = reads.request(afterEdit: afterEdit) else {
            return
        }
        let generation = self.generation
        let work = DnsSettingsReadWork(device: device)
        readOnDeviceWorkQueue(deviceWorkQueue, work.run) { [weak self] answer in
            guard let self, self.generation == generation else {
                return
            }
            let landed = self.reads.landed(read)
            if landed.applies {
                self.apply(answer, afterEdit: read.afterEdit)
            }
            if landed.again {
                self.update()
            }
        }
    }

    private func apply(_ answer: DnsSettingsRead, afterEdit: Bool) {
        if let sdkSettings = answer.settings {
            self.sdkSettings = sdkSettings
            settings = DnsSettings(sdkSettings)
            if afterEdit || answer.connected {
                persist(sdkSettings)
            }
        } else {
            self.sdkSettings = nil
            settings = nil
        }
    }

    /**
     * Re-reads the device's dns resolver status on the device work queue, as
     * `update` reads the settings: GetDnsResolverStatus is an rpc under the
     * device's state lock. The status carries the blocked count as it was
     * read. With the rpc down the device answers the last status it read,
     * which describes the selection it was read for: a status of another
     * selection than the settings reads as unknown
     * (`DescribeDnsResolverStatus`).
     */
    private func updateStatus() {
        guard let device = self.device, let read = statusReads.request() else {
            return
        }
        let generation = self.generation
        let work = DnsResolverStatusReadWork(device: device)
        readOnDeviceWorkQueue(deviceWorkQueue, work.run) { [weak self] answer in
            guard let self, self.generation == generation else {
                return
            }
            let landed = self.statusReads.landed(read)
            if landed.applies {
                self.status = answer.status
                if let status = answer.status {
                    self.blockedCount = status.blockedCount
                }
            }
            if landed.again {
                self.updateStatus()
            }
        }
    }

    /// The dns screen shows the blocked count (`true`) or not: while it does,
    /// the count is read now and every `blockedCountRefreshInterval`. Only
    /// while the store has a device (DeviceStores).
    func setBlockedCountShown(_ shown: Bool) {
        guard blockedCountShown != shown else {
            return
        }
        blockedCountShown = shown
        if shown {
            readBlockedCount()
        }
        updateBlockedCountTimer()
    }

    private func updateBlockedCountTimer() {
        let wanted = blockedCountShown && device != nil
        if !wanted {
            blockedCountTimer?.invalidate()
            blockedCountTimer = nil
            return
        }
        guard blockedCountTimer == nil else {
            return
        }
        blockedCountTimer = Timer.scheduledTimer(withTimeInterval: Self.blockedCountRefreshInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.readBlockedCount()
            }
        }
    }

    /// Reads the count on the device work queue, one read at a time:
    /// GetDnsBlockedCount is an rpc under the device's state lock, and reads
    /// zero while the device cannot be reached.
    private func readBlockedCount() {
        guard let device, !blockedCountReadQueued else {
            return
        }
        blockedCountReadQueued = true
        let generation = self.generation
        let work = DnsBlockedCountReadWork(device: device)
        readOnDeviceWorkQueue(deviceWorkQueue, work.run) { [weak self] count in
            guard let self, self.generation == generation else {
                return
            }
            self.blockedCountReadQueued = false
            self.blockedCount = count
        }
    }

    /// What the summary row and the dns screen show for the settings in
    /// force, given the exit's country (`DescribeDnsResolverSettings`): the
    /// selection, its summary key, the pill, and a dropped preset's notice.
    /// nil while the store has no settings.
    func selectionSummary(exitCountryCode: String?) -> SdkDnsSelectionSummary? {
        guard let sdkSettings else {
            return nil
        }
        return SdkDescribeDnsResolverSettings(sdkSettings, exitCountryCode)
    }

    /// The status line, the verification and the blocked count for the
    /// settings in force (`DescribeDnsResolverStatus`). nil while the store
    /// has no settings.
    var statusSummary: SdkDnsStatusSummary? {
        guard let sdkSettings else {
            return nil
        }
        return SdkDescribeDnsResolverStatus(sdkSettings, status)
    }

    /// The custom editor's starting point (ADBLOCK3RD F2): the settings in
    /// force as custom settings (`DnsResolverSettingsAsCustom`), with the
    /// lists their selection resolves with. nil while the store has none.
    func customDraft() -> DnsSettings? {
        guard let sdkSettings, let custom = SdkDnsResolverSettingsAsCustom(sdkSettings) else {
            return nil
        }
        return DnsSettings(custom)
    }

    /**
     * Writes the settings to the app's own local state.
     *
     * Always the sdk object read back from the device rather than the
     * `DnsSettings` projection, so the fields this app does not model (the
     * upgrade mask address, and any a later sdk adds) survive the mirror. The
     * selection survives it too: the sdk's record carries it.
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

    /**
     * Applies the custom editor's edit made from `original`, the settings it
     * was seeded from, only while they are still the store's: compare and
     * set. The store's settings move under an open editor (a report, another
     * edit, a reset and the next setup), and an edit made from older ones
     * would replace the newer settings whole. With no settings at all (nil
     * until the first read lands, and after a reset) nothing applies: the
     * editor's form would be the blank one, and applied it replaces the
     * resolver the extension holds. Refused, the editor seeds again from the
     * store's settings (SettingsEditorSeed). Returns whether it applied.
     *
     * The edit saves custom settings: the store's sdk settings as custom
     * (`DnsSettings.toCustomSdk`), with the edit's resolver toggles and
     * lists. Fast DNS on connect stays the store's: the screen's own toggle
     * sets it (`setFastDnsOnConnect`).
     */
    @discardableResult
    func apply(_ newSettings: DnsSettings, original: DnsSettings) -> Bool {
        guard device != nil, let settings, settings == original else {
            return false
        }
        var edit = newSettings
        edit.enableFallback = settings.enableFallback
        guard let custom = edit.toCustomSdk(base: sdkSettings) else {
            return false
        }
        push(custom)
        return true
    }

    /**
     * Selects a pick in one tap (ADBLOCK3RD G1, F1): URnetwork's dns
     * (`DnsPresetIdDefault`, which also dismisses a dropped preset's
     * notice), a preset, with the user's id for a personal one, or the exit
     * country's regional pick. The sdk builds the settings from the store's
     * (`DnsResolverSettingsWithPreset`), so Fast DNS on connect and every
     * other field stay. Returns whether it applied: nothing applies while
     * the store has no settings, nor a pick the sdk refuses.
     */
    @discardableResult
    func select(presetId: String, personalId: String = "") -> Bool {
        guard device != nil, let sdkSettings,
              let selected = SdkDnsResolverSettingsWithPreset(sdkSettings, presetId, personalId) else {
            return false
        }
        push(selected)
        return true
    }

    /// Turns Fast DNS on connect on or off (ADBLOCK3RD C7), the selection
    /// and the lists kept (`DnsResolverSettingsWithFallback`). Nothing
    /// applies while the store has no settings.
    func setFastDnsOnConnect(_ enabled: Bool) {
        guard device != nil, let sdkSettings,
              let changed = SdkDnsResolverSettingsWithFallback(sdkSettings, enabled) else {
            return
        }
        push(changed)
    }

    /**
     * Applies an edit. It shows at once, and the device's setter runs on the
     * device work queue, after the work queued so far, never on the main
     * actor: it takes the device's state lock, which a held connect or
     * disconnect command keeps through its rpc, and an Update tapped then
     * froze the main actor until the command returned.
     *
     * The device confirms the edit: its read-back, queued right after the
     * setter, applies and is mirrored (`update`), and so do its listener's
     * reports. A read queued before the edit is dropped (DeviceReads), so
     * what the edit replaced never shows again. Until the read-back lands,
     * the next edit starts from this one. The setter gets a copy of its own
     * (`CopyDnsResolverSettings`).
     */
    private func push(_ newSettings: SdkDnsResolverSettings) {
        guard let device = self.device else {
            return
        }
        reads.edited()
        sdkSettings = newSettings
        settings = DnsSettings(newSettings)
        let work = DnsSettingsEditWork(device: device, settings: SdkCopyDnsResolverSettings(newSettings) ?? newSettings)
        deviceWorkQueue.async {
            work.run()
        }
        update(afterEdit: true)
    }
}

/// An edit's setter, run on the device work queue. Unchecked, as
/// DnsSettingsReadWork: the settings are the edit's own sdk object, which
/// nothing changes after the hand off.
private struct DnsSettingsEditWork: @unchecked Sendable {
    let device: SdkDeviceRemote
    let settings: SdkDnsResolverSettings

    func run() {
        device.setDnsResolverSettings(settings)
    }
}

/// The device's dns resolver settings and its rpc, read on the device work
/// queue. Unchecked: the device is a gomobile proxy that may be called from
/// any thread, and nothing here changes after the hand off.
///
/// `getConnected()` is GetRemoteConnected; swift's importer strips the
/// redundant "Remote".
private struct DnsSettingsReadWork: @unchecked Sendable {
    let device: SdkDeviceRemote

    func run() -> DnsSettingsRead {
        let settings = device.getDnsResolverSettings()
        return DnsSettingsRead(settings: settings, connected: device.getConnected())
    }
}

private struct DnsSettingsRead {
    let settings: SdkDnsResolverSettings?
    let connected: Bool
}

/// The device's dns resolver status, read on the device work queue.
/// Unchecked, as DnsSettingsReadWork.
private struct DnsResolverStatusReadWork: @unchecked Sendable {
    let device: SdkDeviceRemote

    func run() -> DnsResolverStatusRead {
        DnsResolverStatusRead(status: device.getDnsResolverStatus())
    }
}

private struct DnsResolverStatusRead {
    let status: SdkDnsResolverStatus?
}

/// This connection's blocked-lookups count, read on the device work queue.
/// Unchecked, as DnsSettingsReadWork.
private struct DnsBlockedCountReadWork: @unchecked Sendable {
    let device: SdkDeviceRemote

    func run() -> Int64 {
        device.getDnsBlockedCount()
    }
}
