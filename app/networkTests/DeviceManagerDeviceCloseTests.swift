//
//  DeviceManagerDeviceCloseTests.swift
//  networkTests
//

import Foundation
import Testing
import URnetworkSdk
@testable import URnetwork

/// A sign-out's or a sign-in's device change closes the device going away
/// off the main actor, as the quit does (owner report 2026-10-16: "when
/// connect is tapped, the view should immediately change to the connection
/// state"). The sdk's DeviceRemote.Close takes the device's state lock, which
/// a connect or disconnect command still in the sdk keeps through its rpc to
/// the extension, up to the 60 s rpc timeout.
@MainActor
@Suite(.serialized)
struct DeviceManagerDeviceCloseTests {

    /// A device the manager can take: every call setDevice and its listener
    /// setup make is answered here, so nothing reaches the Go side. Its close
    /// is held off the main thread as the sdk's waits on a held command; a
    /// close on the main thread cannot be held (the test releases it from
    /// there), so it returns at once and is counted. Safe for concurrent use.
    final class ManagedDevice: SdkDeviceRemote, @unchecked Sendable {
        private let stateLock = NSLock()
        private var closeCountValue = 0
        private var closedOnMainThreadValue = false
        private let closing = DispatchSemaphore(value: 0)
        private let releases = DispatchSemaphore(value: 0)

        override init() {
            super.init(ref: NSObject())
        }

        override func close() {
            let mainThread = Thread.isMainThread
            stateLock.withLock {
                closeCountValue += 1
                closedOnMainThreadValue = closedOnMainThreadValue || mainThread
            }
            closing.signal()
            if !mainThread {
                releases.wait()
            }
        }

        /// Returns once a close has begun.
        func waitUntilClosing() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.closing.wait()
                    continuation.resume()
                }
            }
        }

        func releaseClose() {
            releases.signal()
        }

        var closeCount: Int {
            stateLock.withLock { closeCountValue }
        }

        var closedOnMainThread: Bool {
            stateLock.withLock { closedOnMainThreadValue }
        }

        // MARK: setDevice's reads and listeners

        override func getProvideControlMode() -> String { ProvideControlMode.Never.rawValue }
        override func getProvideNetworkMode() -> String { ProvideNetworkMode.WiFi.rawValue }
        override func getPerformanceProfile() -> SdkPerformanceProfile? { nil }
        override func getProvideEnabled() -> Bool { false }
        override func getProvidePaused() -> Bool { false }
        override func getProvideMode() -> Int { SdkProvideModeNone }
        override func getExtenderProvideStatus() -> SdkExtenderProvideStatus? { nil }
        override func getInstanceId() -> SdkId? { nil }
        override func getAuthLogoutCause() -> String { "" }

        override func add(_ listener: SdkProvidePausedChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkProvideChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkCanShowRatingDialogChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkCanPromptIntroFunnelChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkAllowForegroundChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkBlockerEnabledChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkCanReferChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkProvideModeChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkProvideNetworkModeChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkVpnInterfaceWhileOfflineChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkDefaultLocationChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkExtenderProvideStatusChangeListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkJwtRefreshListenerProtocol?) -> SdkSubProtocol? { Sub() }
        override func add(_ listener: SdkAuthLogoutListenerProtocol?) -> SdkSubProtocol? { Sub() }

        private final class Sub: NSObject, SdkSubProtocol {
            func close() {}
        }
    }

    /// A manager with no network space and no vpn profiles: it takes the
    /// devices it is given, and nothing else.
    private static func manager() -> DeviceManager {
        DeviceManager(startupMode: .hardwareNoVPN, automaticallyInitialize: false)
    }

    /// The sign-out's clearDevice closed the device on the main actor, and
    /// with a command held it froze there until the command returned. Now the
    /// close is held off it, and the main actor (this test) goes on.
    @Test func signingOutClosesTheDeviceOffTheMainActor() async {
        let manager = Self.manager()
        let device = ManagedDevice()
        manager.setDevice(device: device)
        #expect(manager.device === device)

        manager.clearDevice()
        #expect(manager.device == nil)
        await device.waitUntilClosing()
        #expect(device.closedOnMainThread == false)
        #expect(device.closeCount == 1)
        device.releaseClose()
    }

    /// The next sign-in's device replaces one that is still set: the one
    /// going away closes off the main actor too, and only it.
    @Test func theNextDeviceClosesThePreviousOffTheMainActor() async {
        let manager = Self.manager()
        let previous = ManagedDevice()
        let next = ManagedDevice()
        manager.setDevice(device: previous)

        manager.setDevice(device: next)
        #expect(manager.device === next)
        await previous.waitUntilClosing()
        #expect(previous.closedOnMainThread == false)
        #expect(previous.closeCount == 1)
        #expect(next.closeCount == 0)
        previous.releaseClose()
    }
}
