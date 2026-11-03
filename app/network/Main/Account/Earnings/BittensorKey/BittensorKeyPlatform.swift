//
//  BittensorKeyPlatform.swift
//  URnetwork
//
//  What only this platform can do for the payout key: device authentication,
//  the pasteboard and the local notification (apple/BTEASY.md, Screen privacy).
//  Each sits behind a small protocol, so the model is tested without a device.
//

import Foundation
import LocalAuthentication
import UniformTypeIdentifiers
import UserNotifications
import URnetworkSdk
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: device authentication

protocol BittensorDeviceAuthenticating {
    /// Face ID, Touch ID, or the device passcode or password.
    func authenticate(reason: String) async -> Bool
}

struct BittensorDeviceAuthenticator: BittensorDeviceAuthenticating {

    /// A device with no passcode has nothing to ask for, and its owner must
    /// still be able to save the phrase, so that counts as authenticated. A
    /// failed or cancelled attempt does not.
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// The symbol for what the device asks: Face ID, Touch ID, Optic ID, or a
    /// lock for a passcode, on the controls that ask for it.
    static var systemImage: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "lock"
        }
        switch context.biometryType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        default:
            if #available(iOS 17.0, macOS 14.0, *), context.biometryType == .opticID {
                return "opticid"
            }
            return "lock"
        }
    }
}

// MARK: the pasteboard

protocol BittensorKeyPasteboarding {
    func copy(_ phrase: String)
}

/// An explicit Copy, the only way the phrase reaches a pasteboard. The phrase
/// is not kept here: on macOS what is kept is the change count that says the
/// pasteboard still holds it.
final class BittensorKeyPasteboard: BittensorKeyPasteboarding {

    static let shared = BittensorKeyPasteboard()

    #if canImport(UIKit)

    /// Local only, so no Universal Clipboard, and the system expires it.
    func copy(_ phrase: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: phrase]],
            options: [
                .localOnly: true,
                .expirationDate: Date(timeIntervalSinceNow: TimeInterval(SdkBittensorLocalKeyCopySeconds)),
            ]
        )
    }

    #elseif canImport(AppKit)

    private let pasteboard: BittensorKeyMacPasteboard
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var terminationObserver: NSObjectProtocol?
    private var heldChangeCount: Int?

    init(
        pasteboard: BittensorKeyMacPasteboard = NSPasteboard.general,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.pasteboard = pasteboard
        self.schedule = schedule
    }

    /// This Mac only, marked concealed for the clipboard managers that honor
    /// it, and cleared after 60 s, or when the app quits first, if nothing
    /// replaced it.
    func copy(_ phrase: String) {
        let changeCount = pasteboard.writeConcealed(phrase)
        heldChangeCount = changeCount
        schedule(TimeInterval(SdkBittensorLocalKeyCopySeconds)) { [weak self] in
            self?.clear(ifStill: changeCount)
        }
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.clearHeld()
            }
        }
    }

    private func clearHeld() {
        if let heldChangeCount {
            clear(ifStill: heldChangeCount)
        }
    }

    /// Clears only if nothing wrote to the pasteboard since.
    private func clear(ifStill changeCount: Int) {
        if pasteboard.changeCount == changeCount {
            pasteboard.clearContents()
        }
        if heldChangeCount == changeCount {
            heldChangeCount = nil
        }
    }

    #endif
}

#if canImport(AppKit) && !canImport(UIKit)

/// The general pasteboard, as the copy above uses it.
protocol BittensorKeyMacPasteboard: AnyObject {
    var changeCount: Int { get }
    /// returns the change count that holds the text
    func writeConcealed(_ text: String) -> Int
    @discardableResult func clearContents() -> Int
}

extension NSPasteboard: BittensorKeyMacPasteboard {

    func writeConcealed(_ text: String) -> Int {
        prepareForNewContents(with: .currentHostOnly)
        setString(text, forType: .string)
        setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        return changeCount
    }
}

#endif

// MARK: the local notification

protocol BittensorKeyReminderPosting {
    /// Does what the flow's reminder says, and tells the flow what happened.
    func apply(_ reminder: BittensorKeyReminderInfo, flow: BittensorKeyFlowing)
}

/// The one local notification of an unsaved key. The app asks for notification
/// permission only from Settings, so this never prompts: without permission it
/// reports nothing to the flow, and the Earnings banner does the work.
struct BittensorKeyReminderNotice: BittensorKeyReminderPosting {

    static let identifier = "network.ur.bittensor-key-reminder"

    /// The account is gone, and the key with it.
    static func withdraw() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func apply(_ reminder: BittensorKeyReminderInfo, flow: BittensorKeyFlowing) {
        let center = UNUserNotificationCenter.current()
        switch reminder.action {
        case SdkBittensorLocalKeyReminderCancel:
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        case SdkBittensorLocalKeyReminderSchedule:
            let delay = max(1, TimeInterval(reminder.atMillis) / 1000 - Date().timeIntervalSince1970)
            post(center, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)) {
                flow.reminderScheduled(atMillis: reminder.atMillis)
            }
        case SdkBittensorLocalKeyReminderDeliverNow:
            post(center, trigger: nil) {
                flow.reminderDelivered()
            }
        default:
            break
        }
    }

    private func post(_ center: UNUserNotificationCenter, trigger: UNNotificationTrigger?, posted: @escaping () -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Your first SN25α is claimable")
                content.body = String(localized: "Back up your Bittensor recovery phrase now. If you lose this device before saving it, your SN25α can't be reached.")
                // the same identifier replaces rather than stacks
                let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
                center.add(request) { error in
                    if error == nil {
                        posted()
                    }
                }
            default:
                break
            }
        }
    }
}
