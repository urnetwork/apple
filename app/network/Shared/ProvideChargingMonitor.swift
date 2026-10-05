//
//  ProvideChargingMonitor.swift
//  URnetwork
//
//  Whether this device is on external power, for a provider set to provide
//  only while charging (P077). iOS reads UIDevice battery monitoring; macOS
//  reads the providing IOKit power source, so a Mac without a battery is
//  always on external power. Low Power Mode is read from ProcessInfo where it
//  is needed.
//
//  Compiled into the app and the packet tunnel extensions (listed explicitly
//  in their sources phases). No SDK import, on purpose. The iOS extension
//  already loads UIKit through WidgetKit.
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit.ps
#endif

/// Observes whether this device is on external power. Readable from any
/// thread; `changed` runs on the main queue after the state changes.
final class ProvideChargingMonitor {

    private let lock = NSLock()
    private var cachedCharging: Bool? = nil
    private var started = false
    private var changed: (() -> Void)?
    #if os(iOS)
    private var batteryStateObserver: NSObjectProtocol?
    #elseif os(macOS)
    private var powerSourceRunLoopSource: CFRunLoopSource?
    #endif

    deinit {
        // the power source callback holds an unretained reference
        #if os(macOS)
        if let powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
        }
        #endif
    }

    /// On external power (charging, or full and plugged in); nil until the
    /// device says, and on a device that does not.
    var charging: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return cachedCharging
    }

    /// Starts observing on the main queue. `changed` also runs once the first
    /// reading is in.
    func start(changed: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.started else {
                return
            }
            self.started = true
            self.changed = changed
            #if os(iOS)
            UIDevice.current.isBatteryMonitoringEnabled = true
            self.batteryStateObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.batteryStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.update()
            }
            #elseif os(macOS)
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else {
                    return
                }
                Unmanaged<ProvideChargingMonitor>.fromOpaque(context).takeUnretainedValue().update()
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                self.powerSourceRunLoopSource = source
            }
            #endif
            self.update()
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.started = false
            self.changed = nil
            #if os(iOS)
            if let batteryStateObserver = self.batteryStateObserver {
                NotificationCenter.default.removeObserver(batteryStateObserver)
            }
            self.batteryStateObserver = nil
            #elseif os(macOS)
            if let powerSourceRunLoopSource = self.powerSourceRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoopSource, .defaultMode)
            }
            self.powerSourceRunLoopSource = nil
            #endif
        }
    }

    // main queue
    private func update() {
        guard started else {
            return
        }
        setCharging(Self.readCharging())
        changed?()
    }

    private func setCharging(_ charging: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        cachedCharging = charging
    }

    #if os(iOS)
    // main queue
    private static func readCharging() -> Bool? {
        charging(batteryState: UIDevice.current.batteryState)
    }

    /// Charging or full counts as external power; unknown (monitoring off, or
    /// a simulator) says nothing.
    static func charging(batteryState: UIDevice.BatteryState) -> Bool? {
        switch batteryState {
        case .charging, .full:
            return true
        case .unplugged:
            return false
        case .unknown:
            return nil
        @unknown default:
            return nil
        }
    }
    #elseif os(macOS)
    private static func readCharging() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return nil
        }
        return charging(providingPowerSourceType: type as String)
    }

    /// AC power is external power; a battery or a UPS is not.
    static func charging(providingPowerSourceType type: String) -> Bool? {
        switch type {
        case kIOPMACPowerKey:
            return true
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey:
            return false
        default:
            return nil
        }
    }
    #endif
}
