//
//  AppDelegate.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/30.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import URnetworkSdk
#if os(iOS)
import BackgroundTasks
#endif

#if os(iOS)
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    var deviceManager: DeviceManager?
    
    override init() {
        SdkSetMemoryLimit(48 * 1024 * 1024)
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .allButUpsideDown
        } else {
            return .portrait
        }
    }
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "network.ur.update-tunnel", using: nil) { task in
            guard let deviceManager = self.deviceManager else {
                task.setTaskCompleted(success: false)
                return
            }
            deviceManager.handleBackgroundUpdate(task: task)
        }
        #endif
        return true
    }
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        SdkFreeMemory()
    }
}

#elseif os(macOS)

class AppDelegate: NSObject, NSApplicationDelegate {

    var deviceManager: DeviceManager?
    // its queued connect and disconnect commands reach the sdk before the
    // process exits (QuitSequence)
    var connectViewModel: ConnectViewModel?

    override init() {
        SdkSetMemoryLimit(64 * 1024 * 1024)
    }

    func applicationDidReceiveMemoryWarning(_ notification: Notification) {
        SdkFreeMemory()
    }

    /// Every quit: the app menu's and the menu bar's Quit (which disconnect
    /// first), the Dock's, and a logout, restart or shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let deviceManager = self.deviceManager else {
            return .terminateNow
        }
        let connectViewModel = self.connectViewModel
        QuitSequence(
            settleCommands: {
                await connectViewModel?.connectCommandsSettled()
            },
            close: { closed in
                deviceManager.closeOnQuit { _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            closed()
                        }
                    }
                }
            },
            reply: {
                sender.reply(toApplicationShouldTerminate: true)
            }
        ).start()
        return .terminateLater
    }
}

/**
 * Quitting with connect and disconnect commands still queued: they reach the
 * sdk first (ConnectViewModel.connectCommandsSettled), then the device closes
 * and the vpn profiles are removed (closeOnQuit), then the app answers
 * terminate. Answered before the commands, a disconnect tapped just before a
 * quit was lost, and the next launch reconnected.
 *
 * Bounded, because a logout, restart or shutdown waits on the answer. A
 * queued command returns in well under a second while the tunnel extension
 * answers, but one the extension does not answer waits out the sdk's 60 s
 * rpc timeout, holding the device's state lock. The device starts closing
 * `commandsCap` after the quit whatever the commands do, and the app answers
 * `cap` after the quit at the latest. The cap holds only because nothing on
 * the main actor waits on that lock: closeOnQuit closes the device off the
 * main actor. Closed on it, the close waited on the held command and the
 * quit took up to the rpc timeout instead. A command still held at
 * `commandsCap` is lost, as before. `reply` runs exactly once. Main actor
 * only.
 */
@MainActor
final class QuitSequence {
    /// The longest the quit waits for queued commands before closing.
    static let commandsCap: TimeInterval = 5
    /// The longest the quit takes.
    static let cap: TimeInterval = 10

    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void

    private let settleCommands: @MainActor () async -> Void
    private let close: @MainActor (_ closed: @escaping @MainActor () -> Void) -> Void
    private let reply: @MainActor () -> Void
    private let schedule: Schedule
    private var closing = false
    private var replied = false

    /// `close` closes the device and calls `closed` once it has; `schedule`
    /// runs work after a delay (replaced in tests).
    init(
        settleCommands: @escaping @MainActor () async -> Void,
        close: @escaping @MainActor (_ closed: @escaping @MainActor () -> Void) -> Void,
        reply: @escaping @MainActor () -> Void,
        schedule: @escaping Schedule = QuitSequence.scheduleOnMain
    ) {
        self.settleCommands = settleCommands
        self.close = close
        self.reply = reply
        self.schedule = schedule
    }

    /// The sequence keeps itself alive until it has answered.
    func start() {
        schedule(Self.cap) {
            self.answer()
        }
        schedule(Self.commandsCap) {
            self.closeDevice()
        }
        Task { @MainActor in
            await self.settleCommands()
            self.closeDevice()
        }
    }

    private func closeDevice() {
        if closing {
            return
        }
        closing = true
        close {
            self.answer()
        }
    }

    private func answer() {
        if replied {
            return
        }
        replied = true
        reply()
    }

    nonisolated static func scheduleOnMain(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                work()
            }
        }
    }
}

#endif

//func mainImmediateBlocking(callback: ()->Void) {
//    if Thread.isMainThread {
//        callback()
//    } else {
//        DispatchQueue.main.sync {
//            callback()
//        }
//    }
//}
