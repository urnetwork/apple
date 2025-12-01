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
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    
    override init() {
        SdkSetMemoryLimit(64 * 1024 * 1024)
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .allButUpsideDown
        } else {
            return .portrait
        }
    }
    
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        SdkFreeMemory()
    }
}

#elseif os(macOS)

class AppDelegate: NSObject, NSApplicationDelegate {
    
    var deviceManager: DeviceManager?
    
    override init() {
        SdkSetMemoryLimit(64 * 1024 * 1024)
    }
    
    func applicationDidReceiveMemoryWarning(_ notification: Notification) {
        SdkFreeMemory()
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let deviceManager = self.deviceManager {
            deviceManager.closeOnQuit { _ in
                sender.reply(toApplicationShouldTerminate: true)
            }
            
            return .terminateLater
        } else {
            return .terminateNow
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
