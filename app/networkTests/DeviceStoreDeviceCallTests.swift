//
//  DeviceStoreDeviceCallTests.swift
//  networkTests
//

import Combine
import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// The device stores make no device call on the main actor after their
/// setup (owner report 2026-10-16: "when connect is tapped, the view should
/// immediately change to the connection state").
///
/// On the sdk's DeviceRemote every getter, setter, listener add and close
/// takes the device's state lock, which a connect or disconnect command keeps
/// through its rpc to the extension, up to the sdk's 60 s rpc timeout. Made on
/// the main actor while one is held, a call froze it for as long. Here the
/// stores' device work queue is held (`HeldDeviceWork`) as a held command
/// holds the connect view model's command queue, and the fake device records
/// each call made on the main thread. Nothing waits on time.
@MainActor
@Suite(.serialized)
struct DeviceStoreDeviceCallTests {

    typealias FakeDevice = ConnectTapStateTests.FakeDevice

    /// A device work queue held until `run` lets the work queued so far run,
    /// as a held command holds the command queue. Run it once at least: a
    /// queue released while held crashes.
    final class HeldDeviceWork {
        let queue = DispatchQueue(label: "network.ur.test.device-store-work")
        private var held = true

        init() {
            queue.suspend()
        }

        /// Lets the queued work run and waits for it, and for what it handed
        /// to the main queue.
        func run() async {
            if held {
                held = false
                queue.resume()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Returns once what was queued on the main queue so far has run: the
    /// listeners hop there.
    private static func mainQueueDrained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    // MARK: the peers store

    /// Every peers report logged the device's raw peers, in release builds
    /// too: GetNetworkPeers, an rpc under the device's state lock, made on
    /// the main actor. Now the read is debug only and runs on the device work
    /// queue, one for a burst of reports, and the main actor goes on.
    @Test func aPeersReportMakesNoDeviceCallOnTheMainThread() async throws {
        let work = HeldDeviceWork()
        let device = FakeDevice(location: nil)
        let store = NetworkPeersStore(deviceWorkQueue: work.queue)
        store.setup(device)
        let controller = try #require(device.controller("openPeerViewController"))
        // setup's own calls stay on the main actor: not the report path
        device.forgetMainThreadCalls()

        controller.listeners.reportAll()
        controller.listeners.reportAll()
        controller.listeners.reportAll()
        await Self.mainQueueDrained()
        #expect(device.mainThreadCalls == [])

        await work.run()
        #expect(device.mainThreadCalls == [])
        #if DEBUG
        #expect(device.callCount("getNetworkPeers") == 1)
        #else
        #expect(device.callCount("getNetworkPeers") == 0)
        #endif
        store.reset()
        await work.run()
    }
}
