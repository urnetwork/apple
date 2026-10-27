//
//  PaymentPastDueNotice.swift
//  URnetwork
//
//  The plan cards' past-due notice (see PaymentPastDue): the renewal's payment
//  did not go through, with "Update payment method", which opens ur.io's
//  Manage Subscription in the browser. In the plan area like the crypto
//  renewal notice, never a system notification, and in every build.
//

import SwiftUI

struct PaymentPastDueNotice: View {

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.openURL) private var openURL

    /// Makes the link, with a new one-time code for each tap.
    let updatePaymentMethodURL: () async -> URL

    /// A tap is still making its code, so another tap waits for it.
    @State private var isOpening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your UR Pro payment didn't go through. Update your payment method to keep Pro.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textColor)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                guard !isOpening else {
                    return
                }
                isOpening = true
                Task {
                    let url = await updatePaymentMethodURL()
                    isOpening = false
                    openURL(url)
                }
            }) {
                Text("Update payment method")
                    .font(themeManager.currentTheme.secondaryBodyFont)
            }
            .disabled(isOpening)
            .accessibilityIdentifier("acceptance.paymentPastDue.updatePaymentMethod")
        }
        .padding(.vertical, 8)
    }
}
