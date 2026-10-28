//
//  TransportDelayStoreTests.swift
//  networkTests
//

import Combine
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The slow internet store (apple/DELAY.md §5.1): it registers its listeners
 * before it reads, and both off the main actor; it shows nothing while the
 * device remote is not linked to the extension, never the last level; the
 * reports of a retired setup change nothing; a read older than a report is
 * dropped; and the next setup, on resume, reads again. The device is a fake
 * behind the store's TransportDelayDevice seam, so no sdk device runs.
 */
@MainActor
@Suite(.serialized)
struct TransportDelayStoreTests {

    /// Records each call, on any thread, and hands its listeners back to
    /// the test. Safe for concurrent use.
    final class FakeDevice: TransportDelayDevice, @unchecked Sendable {
        private let stateLock = NSLock()
        private var reading: TransportDelayReading
        private var connected: Bool
        // the value the next read answers once, instead of the reading
        private var nextReadValue: TransportDelayReading?
        private var delayListeners: [Int: (TransportDelayReading) -> Void] = [:]
        private var remoteListeners: [Int: (Bool) -> Void] = [:]
        private var retiredDelayListeners: [(TransportDelayReading) -> Void] = []
        private var nextListenerId = 0
        private var callNames: [String] = []
        private var mainThreadCallNames: [String] = []

        init(reading: TransportDelayReading = .normal, connected: Bool = true) {
            self.reading = reading
            self.connected = connected
        }

        var calls: [String] {
            stateLock.withLock { callNames }
        }

        var mainThreadCalls: [String] {
            stateLock.withLock { mainThreadCallNames }
        }

        func callCount(_ name: String) -> Int {
            stateLock.withLock { callNames.filter { $0 == name }.count }
        }

        var listenerCount: Int {
            stateLock.withLock { delayListeners.count + remoteListeners.count }
        }

        /// The delay listeners whose subs were closed, still callable: a
        /// report already on its way when the store retired them.
        var retiredListeners: [(TransportDelayReading) -> Void] {
            stateLock.withLock { retiredDelayListeners }
        }

        /// The device's reading changed and the sdk reports it.
        func report(_ next: TransportDelayReading) {
            let listeners = stateLock.withLock {
                reading = next
                return Array(delayListeners.values)
            }
            for listener in listeners {
                listener(next)
            }
        }

        /// The device remote's link went up or down and it reports it.
        func reportRemote(_ next: Bool) {
            let listeners = stateLock.withLock {
                connected = next
                return Array(remoteListeners.values)
            }
            for listener in listeners {
                listener(next)
            }
        }

        /// The reading changed without a report (the numbers move on their own).
        func setReadingUnreported(_ next: TransportDelayReading) {
            stateLock.withLock { reading = next }
        }

        /// The next read answers `value` once: a read made before a change.
        func answerNextRead(_ value: TransportDelayReading) {
            stateLock.withLock { nextReadValue = value }
        }

        private func record(_ name: String) {
            let mainThread = Thread.isMainThread
            stateLock.withLock {
                callNames.append(name)
                if mainThread {
                    mainThreadCallNames.append(name)
                }
            }
        }

        func addTransportDelayListener(_ changed: @escaping (TransportDelayReading) -> Void) -> SdkSubProtocol? {
            record("addTransportDelayListener")
            let id = stateLock.withLock {
                nextListenerId += 1
                delayListeners[nextListenerId] = changed
                return nextListenerId
            }
            return FakeSub { [weak self] in
                self?.record("close")
                self?.stateLock.withLock {
                    if let listener = self?.delayListeners.removeValue(forKey: id) {
                        self?.retiredDelayListeners.append(listener)
                    }
                }
            }
        }

        func addRemoteConnectedListener(_ changed: @escaping (Bool) -> Void) -> SdkSubProtocol? {
            record("addRemoteConnectedListener")
            let id = stateLock.withLock {
                nextListenerId += 1
                remoteListeners[nextListenerId] = changed
                return nextListenerId
            }
            return FakeSub { [weak self] in
                self?.record("close")
                _ = self?.stateLock.withLock {
                    self?.remoteListeners.removeValue(forKey: id)
                }
            }
        }

        func readTransportDelay() -> TransportDelayReading {
            record("readTransportDelay")
            return stateLock.withLock {
                if let value = nextReadValue {
                    nextReadValue = nil
                    return value
                }
                return reading
            }
        }

        func readRemoteConnected() -> Bool {
            record("readRemoteConnected")
            return stateLock.withLock { connected }
        }
    }

    private final class FakeSub: NSObject, SdkSubProtocol {
        private let onClose: () -> Void

        init(_ onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func close() {
            onClose()
        }
    }

    private let queue = DispatchQueue(label: "network.ur.test.transport-delay-store")

    /// Runs the work queued on the device work queue so far, and what it
    /// handed to the main queue.
    private func settle() async {
        for _ in 0..<2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Lets a report's hop to the main queue land.
    private func hop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private static let slow = TransportDelayReading(
        upQuality: 0.25,
        downQuality: 0.75,
        upBitsPerSecond: 48_000,
        downBitsPerSecond: 85_000,
        upDelayMillis: 640,
        downDelayMillis: 1200
    )

    // registration does not replay the current value, so the listeners go
    // first and the read after them; all of it on the device work queue,
    // since each takes the device remote's state lock
    @Test func itRegistersFirstThenReadsOffTheMainActor() async {
        let device = FakeDevice(reading: Self.slow)
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()
        #expect(device.calls == [
            "addTransportDelayListener",
            "addRemoteConnectedListener",
            "readTransportDelay",
            "readRemoteConnected",
        ])
        #expect(device.mainThreadCalls.isEmpty)
        #expect(store.state.level == 3)
        #expect(store.state.available)
        #expect(store.state.downDelayMillis == 1200)
        #expect(store.state.worseDirection == .down)
    }

    // the device remote not linked to the extension: the level hides, it is
    // not kept up from before; linked again, the store reads again
    @Test func aDisconnectedRemoteShowsNothing() async {
        let device = FakeDevice(reading: Self.slow, connected: false)
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()
        #expect(!store.state.available)
        #expect(store.state.level == 0)

        // linked: the read made while unlinked answered the device remote's
        // cache, so nothing shows until the read the link queues lands (the
        // queue is held so the read cannot land before the check)
        queue.suspend()
        device.reportRemote(true)
        await hop()
        #expect(store.state.available)
        #expect(store.state.level == 0)
        queue.resume()
        await settle()
        #expect(store.state.level == 3)
        #expect(device.callCount("readTransportDelay") == 2)

        // unlinked again: the level and its reading go at once
        device.setReadingUnreported(TransportDelayReading(downQuality: 1))
        device.reportRemote(false)
        await hop()
        #expect(store.state.level == 0)
        #expect(store.state.reading == .normal)

        // back up: what the device holds now, never the level from before
        queue.suspend()
        device.reportRemote(true)
        await hop()
        #expect(store.state.level == 0)
        queue.resume()
        await settle()
        #expect(store.state.level == 4)
        #expect(device.callCount("readTransportDelay") == 3)
    }

    @Test func aReportPublishesTheNewLevel() async {
        let device = FakeDevice()
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()
        #expect(store.state.level == 0)

        device.report(TransportDelayReading(upQuality: 0.5, fallback: true))
        await hop()
        #expect(store.state.level == 2)
        #expect(store.state.fallback)

        device.report(.normal)
        await hop()
        #expect(store.state.level == 0)
    }

    // a report already on its way from the listener a reset retired changes
    // nothing, after the next setup too
    @Test func theGenerationGuardDropsLateReports() async {
        let first = FakeDevice()
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(first)
        await settle()

        store.reset()
        await settle()
        #expect(first.listenerCount == 0)
        let late = first.retiredListeners
        #expect(late.count == 1)
        for listener in late {
            listener(Self.slow)
        }
        await hop()
        #expect(store.state == TransportDelayState())

        // and after the next setup, on another device
        let second = FakeDevice()
        store.setup(second)
        await settle()
        for listener in late {
            listener(Self.slow)
        }
        await hop()
        #expect(store.state.level == 0)
        #expect(store.state.available)
    }

    // a setup retired before its listeners were added closes them
    @Test func aSetupRetiredBeforeItsListenersLandClosesThem() async {
        let device = FakeDevice(reading: Self.slow)
        let store = TransportDelayStore(deviceWorkQueue: queue)
        queue.suspend()
        store.setup(device)
        store.reset()
        queue.resume()
        await settle()
        await settle()
        #expect(device.listenerCount == 0)
        #expect(device.callCount("close") == 2)
        #expect(store.state == TransportDelayState())
    }

    // a read queued before a report that applied is older than it
    @Test func aReadOlderThanAReportIsDropped() async {
        let device = FakeDevice()
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()

        queue.suspend()
        // the read answers what the device held before the report
        device.answerNextRead(.normal)
        store.refresh()
        device.report(Self.slow)
        await hop()
        #expect(store.state.level == 3)
        queue.resume()
        await settle()
        #expect(store.state.level == 3)
    }

    // the store closes its subs off the main actor and publishes nothing
    // until the next setup, which reads again (a resume)
    @Test func itReadsAgainOnResume() async {
        let device = FakeDevice(reading: Self.slow)
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()
        #expect(store.state.level == 3)

        store.reset()
        #expect(store.state == TransportDelayState())
        await settle()
        #expect(device.listenerCount == 0)
        #expect(!device.mainThreadCalls.contains("close"))

        device.setReadingUnreported(TransportDelayReading(upQuality: 1))
        store.setup(device)
        await settle()
        #expect(device.callCount("readTransportDelay") == 2)
        #expect(store.state.level == 4)
    }

    // the listener fires on every level report, and the store publishes only
    // a change
    @Test func itPublishesOnlyAChange() async {
        let device = FakeDevice(reading: Self.slow)
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()

        var publishes = 0
        let watch = store.objectWillChange.sink { _ in publishes += 1 }
        device.report(Self.slow)
        device.report(Self.slow)
        await hop()
        #expect(publishes == 0)
        device.report(.normal)
        await hop()
        #expect(publishes == 1)
        watch.cancel()
    }

    // the numbers move without a report: the pill reads them again while it
    // shows them
    @Test func thePillReadsTheNumbersAgain() async {
        let device = FakeDevice(reading: Self.slow)
        let store = TransportDelayStore(deviceWorkQueue: queue)
        store.setup(device)
        await settle()

        var moved = Self.slow
        moved.downDelayMillis = 2400
        device.setReadingUnreported(moved)
        store.setPillVisible(true)
        await settle()
        #expect(store.state.downDelayMillis == 2400)
        #expect(device.callCount("readTransportDelay") == 2)
        #expect(device.mainThreadCalls.isEmpty)
        store.setPillVisible(false)
        store.reset()
        await settle()
    }

    // the Developer screen's episode stands in for the device's reading while
    // its slow part plays, so a phone test shows the pill through each level
    @Test func theEpisodeStandsInForTheDeviceWhileItPlays() {
        let device = TransportDelayReading(upQuality: 0.25, upDelayMillis: 150)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = { (elapsed: TimeInterval) in
            TransportDelayStore.reading(device: device, simulationStartedAt: startedAt, now: startedAt.addingTimeInterval(elapsed))
        }
        #expect(TransportDelayStore.reading(device: device, simulationStartedAt: nil, now: startedAt) == device)
        // a delayed start has not begun
        #expect(reading(-30) == device)
        #expect(reading(0).level == 2)
        #expect(reading(40).level == 4)
        #expect(reading(55).level == 3)
        #expect(reading(55) == TransportDelaySimulation.reading(elapsed: 55))
        // after the slow part, the device again
        #expect(reading(75) == device)
    }
}
