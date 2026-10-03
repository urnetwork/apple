//
//  BalanceCodeRedeemedView.swift
//  URnetwork
//

import SwiftUI

/**
 * Post-redeem screen for a balance code: the data the code added.
 *
 * A balance code is data only (see RedeemedBalanceCode). The redeem flows used to
 * present PurchaseSuccessView here, whose default phase says "You're premium.", and
 * start the Pro confirmation poll, which waits for a subscription a code never
 * creates and ends in the "couldn't confirm your purchase" state.
 */
struct BalanceCodeRedeemedView: View {

    @EnvironmentObject var themeManager: ThemeManager

    let redeemed: RedeemedBalanceCode
    var dismiss: () -> Void

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

                    if let message = Self.dataAddedMessage(redeemed) {
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
