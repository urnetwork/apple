//
//  InsufficientBalanceNotice.swift
//  URnetwork
//
//  The local notification for a refused connection: out of balance, or a paying
//  account at a data limit. It says what the traffic is doing, which while the
//  tunnel runs is held in it until the user acts. The app asks for notification
//  permission only from Settings, so this never prompts; it posts only when
//  notifications are already authorized.
//

import Foundation
import UserNotifications

enum InsufficientBalanceNotice {

    static let identifier = "network.ur.insufficient-balance-held"

    static func title(dataLimit: Bool) -> String {
        dataLimit ? String(localized: "Data limit reached") : String(localized: "Insufficient balance")
    }

    /// What the traffic is doing, or nil with no connection requested.
    static func body(dataLimit: Bool, traffic: RefusedTraffic) -> String? {
        switch traffic {
        case .none:
            return nil
        case .held:
            return dataLimit
                ? String(localized: "Your traffic is held in the tunnel until more data is available or you disconnect.")
                : String(localized: "Your traffic is held in the tunnel until you upgrade or disconnect.")
        case .notProtected:
            return String(localized: "Your internet traffic is not protected.")
        }
    }

    static func apply(_ action: InsufficientBalanceNoticeAction) {
        let center = UNUserNotificationCenter.current()
        switch action {
        case .none:
            break
        case let .post(dataLimit, traffic):
            deliver(center, dataLimit: dataLimit, traffic: traffic, replacing: false)
        case let .update(dataLimit, traffic):
            deliver(center, dataLimit: dataLimit, traffic: traffic, replacing: true)
        case .remove:
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    private static func deliver(
        _ center: UNUserNotificationCenter,
        dataLimit: Bool,
        traffic: RefusedTraffic,
        replacing: Bool
    ) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title(dataLimit: dataLimit)
                content.body = body(dataLimit: dataLimit, traffic: traffic) ?? ""
                // a correction goes into the notice in place, without alerting again
                if replacing {
                    content.interruptionLevel = .passive
                }
                // the same identifier replaces rather than stacks
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                center.add(request) { error in
                    if let error {
                        print("[InsufficientBalanceNotice]post failed: \(error.localizedDescription)")
                        return
                    }
                    guard !replacing else {
                        return
                    }
                    DispatchQueue.main.async {
                        InsufficientBalanceNoticePosts.shared.record()
                    }
                }
            default:
                break
            }
        }
    }
}

/// Notices the system accepted in this process. Acceptance builds expose the
/// count as a marker so the insufficient balance acceptance case can prove one
/// post per episode; another app's delivered notifications are not readable
/// from a UI test. Main thread only.
final class InsufficientBalanceNoticePosts: ObservableObject {

    static let shared = InsufficientBalanceNoticePosts()

    @Published private(set) var count = 0

    func record() {
        count += 1
    }
}
