//
//  InsufficientBalanceNotice.swift
//  URnetwork
//
//  The local notification for the insufficient balance state: traffic is held
//  in the tunnel until the user upgrades or disconnects. The app asks for
//  notification permission only from Settings, so this never prompts; it
//  posts only when notifications are already authorized.
//

import Foundation
import UserNotifications

enum InsufficientBalanceNotice {

    static let identifier = "network.ur.insufficient-balance-held"

    static var body: String {
        String(localized: "Your traffic is held in the tunnel until you upgrade or disconnect.")
    }

    static func apply(_ action: InsufficientBalanceNoticeAction) {
        let center = UNUserNotificationCenter.current()
        switch action {
        case .none:
            break
        case .post:
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    let content = UNMutableNotificationContent()
                    content.title = String(localized: "Insufficient balance")
                    content.body = body
                    // the same identifier replaces rather than stacks
                    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                    center.add(request) { error in
                        if let error {
                            print("[InsufficientBalanceNotice]post failed: \(error.localizedDescription)")
                        }
                    }
                default:
                    break
                }
            }
        case .remove:
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }
}
