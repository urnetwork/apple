//
//  PurchaseSuccessView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/26/25.
//

import SwiftUI

/**
 * Post-purchase screen with honest copy per confirmation phase (finding A2).
 *
 * StoreKit reporting success only means the payment was taken; the server
 * learns of the purchase by webhook, and the confirmation poll bridges the
 * gap. This screen used to say "You're premium." at finish() time — before
 * any server confirmation — and the poll's 2-minute give-up had no UI at all:
 * the user paid, saw success, and silently stayed Free.
 *
 * - `.confirming`: payment received, poll still running — processing-shaped
 *   copy, no premium claim.
 * - `.delayed`: the poll gave up (lost or slow webhook). Say so, and offer
 *   "Restore purchases" as the manual retry.
 * - `.confirmed`: the server confirmed the entitlement — the original premium
 *   copy. Also the default, for flows that confirm before presenting (e.g.
 *   balance code redemption).
 */
enum PurchaseConfirmationPhase {
    case confirming
    case delayed
    case confirmed
}

struct PurchaseSuccessView: View {

    @EnvironmentObject var themeManager: ThemeManager

    var phase: PurchaseConfirmationPhase = .confirmed
    var restore: (() -> Void)? = nil
    var isRestoring: Bool = false
    var restoreMessage: String? = nil
    var dismiss: () -> Void

    var body: some View {
        ZStack {
            Image("UpgradeSuccessBackground")
                .resizable()
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                // .edgesIgnoringSafeArea(.all)

            VStack {

                Spacer()

                VStack {

                    HStack {
                        Image("ur.symbols.globe")

                        Spacer()
                    }

                    Spacer().frame(height: 12)

                    HStack {
                        if phase == .confirmed {
                            Text("You're premium.")
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                .font(themeManager.currentTheme.titleCondensedFont)
                        } else {
                            Text("Payment received.")
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                .font(themeManager.currentTheme.titleCondensedFont)
                        }
                        Spacer()
                    }

                    Spacer().frame(height: 8)

                    HStack {
                        switch phase {
                        case .confirmed:
                            Text("Thanks for building the new internet with us")
                                .font(themeManager.currentTheme.titleFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                        case .confirming:
                            Text("We're confirming your purchase with the App Store. Your plan will update automatically.")
                                .font(themeManager.currentTheme.titleFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                        case .delayed:
                            Text("We couldn't confirm your purchase yet. If you completed checkout, your plan will update automatically in a few minutes — there's no need to buy again.")
                                .font(themeManager.currentTheme.titleFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                        }

                        Spacer()
                    }

                    if phase == .confirming {
                        Spacer().frame(height: 16)

                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                            Spacer()
                        }
                    }

                    /**
                     * The delayed phase is a failure state: offer the only
                     * user-triggerable resync (finding A3).
                     */
                    if phase == .delayed, let restore {

                        Spacer().frame(height: 24)

                        UrButton(
                            text: "Restore purchases",
                            action: restore,
                            style: .outlinePrimary,
                            enabled: !isRestoring,
                            isProcessing: isRestoring
                        )

                        if let restoreMessage {
                            Spacer().frame(height: 8)

                            HStack {
                                Text(restoreMessage)
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.inverseTextColor)
                                Spacer()
                            }
                        }
                    }

                    Spacer().frame(height: phase == .confirmed ? 64 : 24)

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
    PurchaseSuccessView(
        dismiss: {}
    )
}
