//
//  ClientLimitNotice.swift
//  URnetwork
//
//  The device's client limit hold, as the app shows it: the platform closed
//  the device for its network's concurrent client limit, and the device holds
//  off reconnecting (the sdk's ClientLimitStatus, read through the device rpc
//  from the tunnel). The connect views show what to do while a connection is
//  requested, and a local notification says it while the app is not in front.
//  What to offer and when the notification shows are the sdk's decisions,
//  the same on every platform (ClientLimitStatus.prompt and
//  ClientLimitNoticeTracker); this file holds only the words and the
//  notification. The app asks for notification permission only from
//  Settings, so this never prompts; it posts only when notifications are
//  already authorized.
//

import Foundation
import UserNotifications
import URnetworkSdk

/// The hold the connect views show while a connection is requested.
struct ClientLimitHold: Equatable {
    /// SdkClientLimitPromptUpgrade or SdkClientLimitPromptRemoveClient
    let prompt: String

    /// A free plan is offered UR Pro; a Pro plan, already the highest, is told
    /// to free a slot. A device process too old to send a prompt reads as free.
    var offersUpgrade: Bool {
        prompt != SdkClientLimitPromptRemoveClient
    }
}

enum ClientLimitNotice {

    static let identifier = "network.ur.client-limit-held"

    static var title: String {
        String(localized: "Device limit reached")
    }

    /// What to do: upgrade or disconnect another device on a free plan, sign
    /// out of an unused device on Pro. The same words answer a sign-in the
    /// limit refused.
    static func body(offersUpgrade: Bool) -> String {
        offersUpgrade
            ? String(localized: "Your free plan connects a limited number of devices at once. Upgrade to UR Pro to connect more, or disconnect URnetwork on another device.")
            : String(localized: "Your plan's limit of devices connected at once is reached. Sign out of URnetwork on a device you no longer use, then try again.")
    }

    /// Applies an action of the sdk's ClientLimitNoticeTracker.
    static func apply(_ action: String, offersUpgrade: Bool) {
        let center = UNUserNotificationCenter.current()
        switch action {
        case SdkClientLimitNoticePost:
            deliver(center, offersUpgrade: offersUpgrade, quietly: false)
        case SdkClientLimitNoticeUpdate:
            deliver(center, offersUpgrade: offersUpgrade, quietly: true)
        case SdkClientLimitNoticeRemove:
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        default:
            break
        }
    }

    private static func deliver(_ center: UNUserNotificationCenter, offersUpgrade: Bool, quietly: Bool) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body(offersUpgrade: offersUpgrade)
                // shown again for the same connection, or corrected: in place,
                // without alerting again
                if quietly {
                    content.interruptionLevel = .passive
                }
                // the same identifier replaces rather than stacks
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                center.add(request) { error in
                    if let error {
                        print("[ClientLimitNotice]post failed: \(error.localizedDescription)")
                    }
                }
            default:
                break
            }
        }
    }
}

/// Hands the device's client limit status changes to a closure.
final class ClientLimitStatusChangeListener: NSObject, SdkClientLimitStatusChangeListenerProtocol {

    private let c: (_ status: SdkClientLimitStatus?) -> Void

    init(c: @escaping (_ status: SdkClientLimitStatus?) -> Void) {
        self.c = c
    }

    func clientLimitStatusChanged(_ status: SdkClientLimitStatus?) {
        c(status)
    }
}
