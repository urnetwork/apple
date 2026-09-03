//
//  WidgetPreviewModel.swift
//  URnetwork
//
//  The live data behind Account > Widgets: the same App Group snapshots the
//  Home Screen widgets render, re-read the moment they change. The tunnel
//  extension and the app post WidgetSnapshotChange (a Darwin notification)
//  whenever a snapshot is written or a widget reload is requested; this model
//  listens for it, watches the snapshot directory as a fallback, follows the
//  tunnel's NEVPNStatus the way the widgets do, and advances the clock once
//  a minute so the chart axis and the "updated" line keep moving. Nothing
//  runs while the screen is off screen or the app is in the background.
//

import Combine
import Foundation
import NetworkExtension
import SwiftUI

/// What the widget previews render: a tunnel and balance snapshot plus the
/// live tunnel state, as the widgets' own timeline entry carries them.
struct WidgetPreviewData {
    var tunnel: WidgetTunnelSnapshot
    var balance: WidgetBalanceSnapshot?
    /// Live tunnel state, from NetworkExtension (the snapshot's own flag can
    /// be stale after the extension is killed without its stop path).
    var isOn: Bool
    var isConfigured: Bool
    /// The clock the previews are drawn for.
    var now: Date
    /// Sample data (onboarding, or no snapshot written yet).
    var isSample: Bool

    /// The tunnel snapshot is meaningful only while the tunnel that wrote it
    /// is still up.
    var showsTunnelData: Bool { isOn && tunnel.tunnelActive }

    /// The widget gallery's sample: what onboarding shows, and what Account >
    /// Widgets shows until the first snapshot exists.
    static func sample(at date: Date = Date()) -> WidgetPreviewData {
        WidgetPreviewData(
            tunnel: WidgetSnapshotSample.tunnel(at: date),
            balance: WidgetSnapshotSample.balance(at: date),
            isOn: true,
            isConfigured: true,
            now: date,
            isSample: true
        )
    }
}

@MainActor
final class WidgetPreviewModel: ObservableObject {

    @Published private(set) var data: WidgetPreviewData = .sample()

    /// The app's tunnel configuration, matched by provider bundle id (a
    /// device with several VPN apps has several configurations).
    private static let providerBundleIdentifier = "network.ur.extension"
    /// Snapshot writes and reload requests arrive in bursts (the tunnel
    /// snapshot, then a reload per widget); one re-read covers them.
    private static let coalesceInterval: TimeInterval = 0.1
    /// The chart's bucket is a minute; the clock advances at that cadence.
    private static let tickInterval: TimeInterval = 60

    private var running = false
    private var manager: NETunnelProviderManager?
    private var observers: [NSObjectProtocol] = []
    private var directorySource: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var tick: Timer?

    func start() {
        guard !running else { return }
        running = true
        WidgetSnapshotChangeListener.shared.register()
        observers.append(NotificationCenter.default.addObserver(
            forName: WidgetSnapshotChangeListener.notification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        })
        // the tunnel going up or down re-renders the widgets; follow it here
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.loadManager() }
        })
        watchDirectory()
        tick = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        Task { await loadManager() }
        reload()
    }

    func stop() {
        guard running else { return }
        running = false
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        directorySource?.cancel()
        directorySource = nil
        reloadWork?.cancel()
        reloadWork = nil
        tick?.invalidate()
        tick = nil
    }

    /// Re-read the snapshots and the tunnel state.
    func reload() {
        guard running else { return }
        let now = Date()
        let tunnel = WidgetSnapshotStore.loadTunnel()
        let balance = WidgetSnapshotStore.loadBalance()
        guard tunnel != nil || balance != nil else {
            // nothing has been written yet (fresh install, never connected):
            // show what the widgets themselves show in that state, the sample
            data = .sample(at: now)
            return
        }
        data = WidgetPreviewData(
            tunnel: tunnel ?? .inactive(at: now),
            balance: balance,
            isOn: manager.map { Self.isActive($0.connection.status) } ?? false,
            isConfigured: manager != nil,
            now: now,
            isSample: false
        )
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.reload() }
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: work)
    }

    /// Whether the tunnel counts as on, as the widgets decide it.
    private static func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        case .disconnected, .disconnecting, .invalid:
            return false
        @unknown default:
            return false
        }
    }

    private func loadManager() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == Self.providerBundleIdentifier
        }
        reload()
    }

    /// Fallback for a missed Darwin notification: the snapshot directory's
    /// entries change on every atomic write (a temp file renamed into place).
    private func watchDirectory() {
        guard let directory = WidgetSnapshotStore.directoryURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard 0 <= descriptor else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleReload() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }
}

/// One Darwin observer per process, rebroadcast as a NotificationCenter
/// notification (a Darwin callback is a C function pointer and cannot carry
/// a reference to a model).
private final class WidgetSnapshotChangeListener {

    static let shared = WidgetSnapshotChangeListener()
    static let notification = Notification.Name("network.ur.widgets.snapshot-changed.local")

    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: WidgetSnapshotChangeListener.notification, object: nil)
                }
            },
            WidgetSnapshotChange.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }
}
