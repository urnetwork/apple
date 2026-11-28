//
//  LowDataWarningNotice.swift
//  URnetwork
//
//  The low-data warning as the app shows it: little data is left before the
//  balance runs out. When to warn is the sdk's decision, the same on every
//  platform (LowDataWarningForBalance: once at 10% of the period's data and
//  once at 1 GiB, per balance period); this file holds only the words, the
//  alert and the notification. The warning only informs: nothing disconnects,
//  and at zero the out-of-balance notice takes over. The app asks for
//  notification permission only from Settings, so this never prompts; it
//  posts only when notifications are already authorized, and none shows while
//  the app is in front (AppNotificationDelegate), where the alert says it.
//

import Foundation
import SwiftUI
import UserNotifications
import URnetworkSdk

enum LowDataWarningNotice {

    static let identifier = "network.ur.low-data-warning"

    static var title: String {
        String(localized: "Running low on data")
    }

    /// How much is left: the part of the period's data for the percent
    /// threshold, the amount for the byte count one.
    static func body(_ warning: SdkLowDataWarning) -> String {
        let amount = formatBalanceBytes(Int(warning.availableByteCount))
        if warning.kind == SdkLowDataWarningKindPercent {
            return String(
                format: String(localized: "Only %lld%% of your data is left (%@)."),
                Int(warning.availablePercent),
                amount
            )
        }
        return String(format: String(localized: "Only %@ of data is left."), amount)
    }

    static func post(body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                // a later warning replaces an earlier one rather than stacking
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
                center.add(request) { error in
                    if let error {
                        print("[LowDataWarningNotice]post failed: \(error.localizedDescription)")
                    }
                }
            default:
                break
            }
        }
    }
}

/// The in-app alert of a low-data warning: Got it, and Get Pro on a plan that
/// is not Pro, which opens the upgrade sheet.
struct LowDataWarningAlert: ViewModifier {

    let openUpgrade: () -> Void

    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var deviceManager: DeviceManager

    func body(content: Content) -> some View {
        content.alert(
            LowDataWarningNotice.title,
            isPresented: Binding(
                get: { subscriptionBalanceViewModel.lowDataWarningMessage != nil },
                set: { presented in
                    if !presented {
                        subscriptionBalanceViewModel.dismissLowDataWarning()
                    }
                }
            ),
            presenting: subscriptionBalanceViewModel.lowDataWarningMessage
        ) { _ in
            if !deviceManager.isPro {
                Button(String(localized: "Get Pro")) {
                    subscriptionBalanceViewModel.dismissLowDataWarning()
                    openUpgrade()
                }
            }
            Button(String(localized: "Got it"), role: .cancel) {
                subscriptionBalanceViewModel.dismissLowDataWarning()
            }
        } message: { message in
            Text(verbatim: message)
        }
    }
}
