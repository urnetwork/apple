//
//  TransportDelayStore.swift
//  URnetwork
//
//  The device's transport delay for the slow internet pill and the macOS
//  menu bar row (apple/DELAY.md §5.1). The quality is measured in the network
//  extension's device; the app's device remote relays it.
//

import Combine
import Foundation
import URnetworkSdk

/// What the slow internet indicator draws, published by TransportDelayStore.
struct TransportDelayState: Equatable {
    /// The device's last reading.
    var reading: TransportDelayReading = .normal
    /// The device remote is linked to the extension, so the reading is live.
    /// While it is not, the reading may be stale and nothing shows (the
    /// device-remote stale stat rule).
    var available = false

    /// The level that shows, 0 to 4: the worse direction's, 0 while
    /// unavailable.
    var level: Int {
        available ? reading.level : 0
    }

    var upDelayMillis: Int64 { reading.upDelayMillis }
    var downDelayMillis: Int64 { reading.downDelayMillis }
    var upBitsPerSecond: Int64 { reading.upBitsPerSecond }
    var downBitsPerSecond: Int64 { reading.downBitsPerSecond }
    /// Switches the copy only (§4): the tunnel and its motion are the same.
    var fallback: Bool { reading.fallback }

    var worseDirection: TransportDelayDirection? {
        TransportDelayDirection.worse(upDelayMillis: upDelayMillis, downDelayMillis: downDelayMillis)
    }
}

/// The device as the store reads it. A protocol so the tests stand in for
/// the sdk; the app's device remote is the one implementation.
protocol TransportDelayDevice: AnyObject {
    /// Reports every change of either direction's level or of the fallback;
    /// the numbers ride along but do not report on their own. Closing the sub
    /// stops it.
    func addTransportDelayListener(_ changed: @escaping (TransportDelayReading) -> Void) -> SdkSubProtocol?
    /// Reports the device remote's link to the extension going up or down.
    func addRemoteConnectedListener(_ changed: @escaping (Bool) -> Void) -> SdkSubProtocol?
    func readTransportDelay() -> TransportDelayReading
    func readRemoteConnected() -> Bool
}

/**
 * Publishes the device's transport delay.
 *
 * The listener reports level changes and one read covers the time before
 * the first (registration does not replay the current value), so the store
 * registers first and reads after. The registration and the read take the
 * device remote's state lock and the read can wait on the rpc for up to its
 * timeout, so both run on the device work queue (DeviceStores), never on the
 * main actor; their answers apply there. A read made before a report that
 * applied is older than it and is dropped.
 *
 * While the device remote is not linked to the extension (`getConnected`
 * false) the state is unavailable and draws nothing, rather than the last
 * level, and the reading is dropped: the link coming back is pushed
 * (RemoteChangeListener), and the store reads again then.
 *
 * DeviceStores sets it up with the window and resets it when the
 * presentation suspends, after which the next setup reads again. The macOS
 * menu bar keeps one of its own for the device's life, window shown or not.
 *
 * While the Developer screen's scripted episode plays (TransportDelaySimulation),
 * its reading stands in for the device's, so a phone test shows the pill
 * through each level with no slow network. It still needs the link: an
 * unavailable state draws nothing either way.
 */
@MainActor
class TransportDelayStore: ObservableObject {

    /// How often the pill re-reads the numbers while it shows them: the
    /// listener reports level changes only.
    static let pillRefreshInterval: TimeInterval = 10

    @Published private(set) var state = TransportDelayState()

    private(set) var device: TransportDelayDevice?
    private var subs: [SdkSubProtocol] = []
    // the device's subs and reads run here, off the main actor (DeviceStores)
    private let deviceWorkQueue: DispatchQueue
    // advanced by every reset: a report from a retired listener, or a read
    // for one, changes nothing, after the next setup too
    private var generation = 0
    // the reports applied, per value: a read queued before one of them is
    // older than it
    private var readingRevision = 0
    private var remoteRevision = 0
    // a re-read of the reading is queued and has not landed
    private var readQueued = false
    private var pillVisible = false
    private var refreshTimer: Timer?
    // the device's last reading: `state.reading` is it, or the episode's
    // while one plays
    private var deviceReading: TransportDelayReading = .normal
    private var simulationStartedAt: Date?
    // steps at each change of the episode's reading
    private var simulationTimer: Timer?
    private var simulationSub: AnyCancellable?

    init(deviceWorkQueue: DispatchQueue = newDeviceWorkQueue()) {
        self.deviceWorkQueue = deviceWorkQueue
        // the Developer screen's Play and Stop (this process only: the
        // episode is started from the app)
        simulationSub = TransportDelayLiveActivityPreference.shared.$simulationStartedAt
            .sink { [weak self] startedAt in
                DispatchQueue.main.async {
                    self?.setSimulation(startedAt)
                }
            }
    }

    /// The reading that shows: the scripted episode's while its slow part
    /// plays, else the device's.
    static func reading(device: TransportDelayReading, simulationStartedAt: Date?, now: Date) -> TransportDelayReading {
        guard let simulationStartedAt,
              let simulated = TransportDelaySimulation.reading(elapsed: now.timeIntervalSince(simulationStartedAt)) else {
            return device
        }
        return simulated
    }

    func setup(_ device: TransportDelayDevice) {
        reset()

        self.device = device
        let generation = self.generation
        let readingRevision = self.readingRevision
        let remoteRevision = self.remoteRevision
        let work = TransportDelayListenWork(
            device: device,
            readingChanged: { [weak self] reading in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else {
                        return
                    }
                    self.readingRevision += 1
                    self.publish(reading: reading)
                }
            },
            remoteChanged: { [weak self] connected in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else {
                        return
                    }
                    self.remoteRevision += 1
                    self.publish(available: connected)
                    if connected {
                        // the link is back: what the device holds now, not
                        // the level from before it went down
                        self.refresh()
                    }
                }
            }
        )
        let queue = deviceWorkQueue
        queue.async { [weak self] in
            let listened = work.run()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else {
                    closeOnDeviceWorkQueue(queue, listened.subs)
                    return
                }
                self.subs = listened.subs
                if self.remoteRevision == remoteRevision {
                    self.publish(available: listened.connected)
                }
                // unlinked, the read answered the device remote's cache
                if self.readingRevision == readingRevision && self.state.available {
                    self.publish(reading: listened.reading)
                }
                self.updateRefreshTimer()
            }
        }
    }

    /// Makes no call on the device: its subs take the device's state lock
    /// and close on the device work queue (DeviceStores).
    func reset() {
        generation += 1
        closeOnDeviceWorkQueue(deviceWorkQueue, subs)
        subs = []
        device = nil
        readQueued = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        deviceReading = .normal
        if state != TransportDelayState() {
            state = TransportDelayState()
        }
    }

    /// Reads the device's reading again, on the device work queue: the
    /// numbers move without a report. One read at a time.
    func refresh() {
        guard let device, !readQueued else {
            return
        }
        readQueued = true
        let generation = self.generation
        let readingRevision = self.readingRevision
        let read = TransportDelayReadWork(device: device)
        readOnDeviceWorkQueue(deviceWorkQueue, read.run) { [weak self] reading in
            guard let self, self.generation == generation else {
                return
            }
            self.readQueued = false
            if self.readingRevision == readingRevision && self.state.available {
                self.publish(reading: reading)
            }
        }
    }

    /// The pill shows the numbers (`true`) or not: while it does they are
    /// read again every `pillRefreshInterval`. Only while the app is active,
    /// since the store has no device while it is suspended (DeviceStores).
    func setPillVisible(_ visible: Bool) {
        guard pillVisible != visible else {
            return
        }
        pillVisible = visible
        if visible {
            refresh()
        }
        updateRefreshTimer()
    }

    private func updateRefreshTimer() {
        let wanted = pillVisible && device != nil
        if !wanted {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else {
            return
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.pillRefreshInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    /// Publishes only a change.
    private func publish(reading: TransportDelayReading) {
        deviceReading = reading
        applyReading()
    }

    private func applyReading() {
        let reading = Self.reading(device: deviceReading, simulationStartedAt: simulationStartedAt, now: Date())
        guard reading != state.reading else {
            return
        }
        state.reading = reading
    }

    private func setSimulation(_ startedAt: Date?) {
        simulationStartedAt = startedAt
        if state.available {
            applyReading()
        }
        scheduleSimulation()
    }

    /// While an episode is due or plays, steps at its next change, the end of
    /// its slow part included: the device does not report it.
    private func scheduleSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
        guard let simulationStartedAt else {
            return
        }
        let elapsed = Date().timeIntervalSince(simulationStartedAt)
        guard let next = TransportDelaySimulation.nextChange(after: elapsed) else {
            return
        }
        // a little past the change, so the read there lands on the new reading
        simulationTimer = Timer.scheduledTimer(withTimeInterval: max(0, next - elapsed) + 0.05, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if self.state.available {
                    self.applyReading()
                }
                self.scheduleSimulation()
            }
        }
    }

    /// Unlinked, the reading is dropped too: the device remote's value is
    /// only its cache then, and the link coming back must not show it again
    /// before the re-read or the extension's replay lands.
    private func publish(available: Bool) {
        var next = state
        next.available = available
        if !available {
            deviceReading = .normal
            next.reading = .normal
        }
        guard next != state else {
            return
        }
        state = next
    }
}

/// The listeners added, then the reading and the link read, on the device
/// work queue. Unchecked: the device is a gomobile proxy that may be called
/// from any thread, and nothing here changes after the hand off.
private struct TransportDelayListenWork: @unchecked Sendable {
    let device: TransportDelayDevice
    let readingChanged: (TransportDelayReading) -> Void
    let remoteChanged: (Bool) -> Void

    struct Listened: @unchecked Sendable {
        let subs: [SdkSubProtocol]
        let reading: TransportDelayReading
        let connected: Bool
    }

    func run() -> Listened {
        // registration first: it does not replay the current value
        let subs = [
            device.addTransportDelayListener(readingChanged),
            device.addRemoteConnectedListener(remoteChanged),
        ].compactMap { $0 }
        return Listened(
            subs: subs,
            reading: device.readTransportDelay(),
            connected: device.readRemoteConnected()
        )
    }
}

/// A re-read on the device work queue. Unchecked, as TransportDelayListenWork.
private struct TransportDelayReadWork: @unchecked Sendable {
    let device: TransportDelayDevice

    func run() -> TransportDelayReading {
        device.readTransportDelay()
    }
}

// MARK: - The sdk

extension TransportDelayReading {

    /// A copy of the sdk's reading; nil (never sent, but the binding is
    /// optional) reads as normal.
    init(_ delay: SdkTransportDelay?) {
        guard let delay else {
            self = .normal
            return
        }
        self.init(
            upQuality: delay.upQuality,
            downQuality: delay.downQuality,
            upBitsPerSecond: delay.upBitsPerSecond,
            downBitsPerSecond: delay.downBitsPerSecond,
            upDelayMillis: delay.upQueueDelayMillis,
            downDelayMillis: delay.downQueueDelayMillis,
            fallback: delay.fallback
        )
    }
}

private class TransportDelayChangeListener: NSObject, SdkTransportDelayChangeListenerProtocol {
    private let callback: (SdkTransportDelay?) -> Void
    init(callback: @escaping (SdkTransportDelay?) -> Void) {
        self.callback = callback
    }
    func transportDelayChanged(_ delay: SdkTransportDelay?) {
        callback(delay)
    }
}

private class TransportDelayRemoteListener: NSObject, SdkRemoteChangeListenerProtocol {
    private let callback: (Bool) -> Void
    init(callback: @escaping (Bool) -> Void) {
        self.callback = callback
    }
    func remoteChanged(_ remoteConnected: Bool) {
        callback(remoteConnected)
    }
}

extension SdkDeviceRemote: TransportDelayDevice {

    func addTransportDelayListener(_ changed: @escaping (TransportDelayReading) -> Void) -> SdkSubProtocol? {
        // `AddTransportDelayChangeListener` binds as `add(_:)`: the selector
        // names the listener type, which swift strips
        add(TransportDelayChangeListener { delay in
            changed(TransportDelayReading(delay))
        })
    }

    func addRemoteConnectedListener(_ changed: @escaping (Bool) -> Void) -> SdkSubProtocol? {
        add(TransportDelayRemoteListener(callback: changed))
    }

    func readTransportDelay() -> TransportDelayReading {
        TransportDelayReading(getTransportDelay())
    }

    func readRemoteConnected() -> Bool {
        // GetRemoteConnected: swift's importer strips the redundant "Remote"
        getConnected()
    }
}
