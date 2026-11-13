//
//  BalanceCodeRedeemedView.swift
//  URnetwork
//

import SwiftUI

/**
 * Post-redeem screen for a balance code: the data a data code added, or the year
 * of Pro a gift code granted (mmm/GIFTOFPRIVACY.md §5, §10.5).
 *
 * See RedeemedBalanceCode. The redeem flows used to present PurchaseSuccessView
 * here, whose default phase says "You're premium.", and start the Pro
 * confirmation poll, which waits for a store purchase a code never makes and
 * ends in the "couldn't confirm your purchase" state.
 */
struct BalanceCodeRedeemedView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let redeemed: RedeemedBalanceCode
    var dismiss: () -> Void

    /// The line under the title: a gift code's year of Pro in place of the data
    /// line, or the data a data code added. nil when a data code's answer
    /// carried no byte count (the title alone confirms the redeem).
    static func message(_ redeemed: RedeemedBalanceCode) -> String? {
        if let pro = redeemed.pro {
            return proGrantedMessage(pro)
        }
        return dataAddedMessage(redeemed)
    }

    /// A gift code's year of Pro. A queued year, after the Pro the network
    /// already pays for, says when it starts, as a long date with no time (the
    /// way the crypto renew notice dates a Pro period).
    static func proGrantedMessage(_ pro: RedeemedBalanceCode.ProGrant) -> String {
        if pro.queued, let startTime = pro.startTime {
            let dateText = startTime.formatted(date: .long, time: .omitted)
            return String(localized: "Your gift year of Pro starts on \(dateText), after your current Pro period.")
        }
        return String(localized: "A year of Pro is yours.")
    }

    /// nil when the answer carried no byte count (the title alone confirms the redeem)
    static func dataAddedMessage(_ redeemed: RedeemedBalanceCode) -> String? {
        guard 0 < redeemed.addedByteCount else {
            return nil
        }
        let amount = formatBalanceBytes(Int(redeemed.addedByteCount))
        return String(localized: "\(amount) of data added to your balance.")
    }

    var body: some View {
        ZStack {
            Image("UpgradeSuccessBackground")
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()

            VStack {

                Spacer()

                VStack {

                    HStack {
                        Image("ur.symbols.globe")

                        Spacer()
                    }

                    Spacer().frame(height: 12)

                    HStack {
                        Text("Balance code redeemed.")
                            .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            .font(themeManager.currentTheme.titleCondensedFont)
                        Spacer()
                    }

                    if let message = Self.message(redeemed) {
                        Spacer().frame(height: 8)

                        HStack {
                            Text(message)
                                .font(themeManager.currentTheme.titleFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            Spacer()
                        }
                    }

                    Spacer().frame(height: 64)

                    UrButton(
                        text: "Close",
                        action: {
                            dismiss()
                        },
                        style: .outlinePrimary
                    )

                }
                .padding(24)
                .background(.urLightYellow)
                .cornerRadius(12)
                .padding()
                .frame(maxWidth: .infinity)

            }
            .frame(maxWidth: .infinity)

        }
    }

}

#Preview {
    BalanceCodeRedeemedView(
        redeemed: RedeemedBalanceCode(addedByteCount: 5 * 1024 * 1024 * 1024),
        dismiss: {}
    )
}
