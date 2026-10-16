//
//  ProviderStatusStoreTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/**
 * The provider status controller's lifecycle (P008): it opens only when the
 * demand chart shows, polls only while it shows, and is closed with the
 * typed close, listener first, when the device goes or the presentation
 * suspends.
 */
@MainActor
struct ProviderStatusStoreTests {

    private final class Events {
        var log: [String] = []
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

    private final class FakeController: ProviderStatusControlling {
        private let events: Events
        var snapshot = ProviderStatusSnapshot()
        var listener: (() -> Void)?

        init(_ events: Events) {
            self.events = events
        }

        func start() {
            events.log.append("start")
        }

        func stop() {
            events.log.append("stop")
        }

        func addStatusListener(_ changed: @escaping () -> Void) -> SdkSubProtocol? {
            listener = changed
            events.log.append("listen")
            return FakeSub { [events] in
                events.log.append("unlisten")
            }
        }

        func readSnapshot() -> ProviderStatusSnapshot {
            snapshot
        }
    }

    private final class FakeOwner: ProviderStatusControllerOwner {
        private let events: Events
        var opened: [FakeController] = []
        var closed: [FakeController] = []

        init(_ events: Events) {
            self.events = events
        }

        func openProviderStatusController() -> ProviderStatusControlling? {
            let controller = FakeController(events)
            opened.append(controller)
            events.log.append("open")
            return controller
        }

        func closeProviderStatusController(_ controller: ProviderStatusControlling) {
            if let controller = controller as? FakeController {
                closed.append(controller)
            }
            events.log.append("close")
        }
    }

    /// The device work queue the store's typed close runs on (it goes
    /// through the device, see DeviceStores), held until `run` lets the
    /// closes queued so far run: nothing else touches the fakes meanwhile.
    private final class HeldDeviceWork {
        let queue = DispatchQueue(label: "network.ur.test.provider-status-device-work")
        private var held = true

        init() {
            queue.suspend()
        }

        /// Lets the queued closes run, and waits for them. Run once at least:
        /// a queue released while held crashes.
        func run() async {
            if held {
                held = false
                queue.resume()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    continuation.resume()
                }
            }
        }
    }

    /// Waits for the main queue to run what is queued on it so far, which
    /// includes a listener's hop to the main queue.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    // providing disabled or the chart off screen: nothing is opened
    @Test func theControllerIsNotOpenedUntilTheChartShows() {
        let events = Events()
        let owner = FakeOwner(events)
        let store = ProviderStatusStore()
        store.setup(owner: owner)
        store.setVisible(false)
        #expect(owner.opened.isEmpty)
        #expect(events.log.isEmpty)
    }

    @Test func showingTheChartOpensListensAndStarts() {
        let events = Events()
        let owner = FakeOwner(events)
        let store = ProviderStatusStore()
        store.setup(owner: owner)
        store.setVisible(true)
        #expect(owner.opened.count == 1)
        #expect(events.log == ["open", "listen", "start"])
    }

    // hiding stops polling; showing again reuses the controller
    @Test func hidingTheChartStopsAndShowingRestarts() {
        let events = Events()
        let owner = FakeOwner(events)
        let store = ProviderStatusStore()
        store.setup(owner: owner)
        store.setVisible(true)
        store.setVisible(false)
        store.setVisible(true)
        #expect(owner.opened.count == 1)
        #expect(owner.closed.isEmpty)
        #expect(events.log == ["open", "listen", "start", "stop", "start"])
    }

    @Test func repeatedVisibilityIsIgnored() {
        let events = Events()
        let owner = FakeOwner(events)
        let store = ProviderStatusStore()
        store.setup(owner: owner)
        store.setVisible(true)
        store.setVisible(true)
        store.setVisible(false)
        store.setVisible(false)
        #expect(events.log == ["open", "listen", "start", "stop"])
    }

    // the typed close, after the listener is dropped and polling stops: those
    // two at once, the close on the device work queue
    @Test func resetDropsTheListenerThenStopsAndCloses() async {
        let events = Events()
        let owner = FakeOwner(events)
        let deviceWork = HeldDeviceWork()
        let store = ProviderStatusStore(deviceWorkQueue: deviceWork.queue)
        store.setup(owner: owner)
        store.setVisible(true)
        events.log = []
        store.reset()
        #expect(events.log == ["unlisten", "stop"])
        await deviceWork.run()
        #expect(events.log == ["unlisten", "stop", "close"])
        #expect(owner.closed.count == 1)
        #expect(owner.closed.first === owner.opened.first)
        // closed once
        store.reset()
        await deviceWork.run()
        #expect(owner.closed.count == 1)
    }

    @Test func aHiddenChartIsStillClosedOnReset() async {
        let events = Events()
        let owner = FakeOwner(events)
        let deviceWork = HeldDeviceWork()
        let store = ProviderStatusStore(deviceWorkQueue: deviceWork.queue)
        store.setup(owner: owner)
        store.setVisible(true)
        store.setVisible(false)
        store.reset()
        await deviceWork.run()
        #expect(owner.closed.count == 1)
    }

    // a new device (or a resumed presentation) while the chart shows opens a
    // fresh controller and closes the old one, on the device work queue
    @Test func aNewDeviceWhileShownOpensAFreshController() async {
        let events = Events()
        let first = FakeOwner(events)
        let second = FakeOwner(events)
        let deviceWork = HeldDeviceWork()
        let store = ProviderStatusStore(deviceWorkQueue: deviceWork.queue)
        store.setup(owner: first)
        store.setVisible(true)
        store.setup(owner: second)
        #expect(first.closed.isEmpty)
        #expect(second.opened.count == 1)
        await deviceWork.run()
        #expect(first.closed.count == 1)
        #expect(events.log == ["open", "listen", "start", "unlisten", "stop", "open", "listen", "start", "close"])
    }

    // a poll reported as the chart's device goes reads nothing, from the
    // retired controller or the next device's
    @Test func aReportFromARetiredControllerChangesNothing() async throws {
        let events = Events()
        let first = FakeOwner(events)
        let second = FakeOwner(events)
        let deviceWork = HeldDeviceWork()
        let store = ProviderStatusStore(deviceWorkQueue: deviceWork.queue)
        store.setup(owner: first)
        store.setVisible(true)
        let retired = try #require(first.opened.first)
        var loaded = ProviderStatusSnapshot()
        loaded.isLoaded = true
        retired.snapshot = loaded
        // on its way to the main queue as the device goes
        let listener = try #require(retired.listener)
        listener()
        store.setup(owner: second)
        let next = try #require(second.opened.first)
        next.snapshot = loaded
        await drainMainQueue()
        #expect(store.snapshot == ProviderStatusSnapshot())
        await deviceWork.run()
    }

    @Test func noDeviceOpensNothing() {
        let store = ProviderStatusStore()
        store.setVisible(true)
        #expect(store.snapshot == ProviderStatusSnapshot())
        store.setVisible(false)
        store.reset()
    }

    @Test func aListenerCallPublishesTheSnapshot() async throws {
        let events = Events()
        let owner = FakeOwner(events)
        let store = ProviderStatusStore()
        store.setup(owner: owner)
        store.setVisible(true)
        let controller = try #require(owner.opened.first)
        #expect(store.snapshot == ProviderStatusSnapshot())

        var loaded = ProviderStatusSnapshot()
        loaded.isLoaded = true
        loaded.hasStatus = true
        loaded.reason = SdkProviderStatusReasonReliabilityWarmingUp
        loaded.appearancesPerMinute = [Int64](repeating: 1, count: 60)
        controller.snapshot = loaded
        // the sdk calls back on its own thread
        let listener = try #require(controller.listener)
        await Task.detached {
            listener()
        }.value
        await drainMainQueue()
        #expect(store.snapshot == loaded)

        // the reset clears what the screen shows
        store.reset()
        #expect(store.snapshot == ProviderStatusSnapshot())
    }
}
