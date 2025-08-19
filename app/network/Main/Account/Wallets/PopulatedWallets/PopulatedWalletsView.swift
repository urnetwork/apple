//
//  PopulatedWalletsView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/17.
//

import SwiftUI
import URnetworkSdk

struct PopulatedWalletsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var accountPaymentsViewModel: AccountPaymentsViewModel
    @EnvironmentObject var accountWalletsViewModel: AccountWalletsViewModel
    @EnvironmentObject var payoutWalletViewModel: PayoutWalletViewModel

    var navigate: (AccountNavigationPath) -> Void
    var isSeekerOrSagaHolder: Bool
    var netPoints: Double
    var payoutPoints: Double
    var referralPoints: Double
    var multiplierPoints: Double
    var reliabilityPoints: Double
    @Binding var presentConnectWalletSheet: Bool

    var body: some View {

        if accountWalletsViewModel.isRemovingWallet {

            VStack {
                Spacer().frame(height: 64)
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }

        } else {

            VStack(spacing: 0) {

                HStack {

                    Text("Wallets")
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .font(themeManager.currentTheme.bodyFont)

                    Spacer()

                    Button(action: {
                        presentConnectWalletSheet = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                            .frame(width: 26, height: 26)
                            .background(themeManager.currentTheme.tintedBackgroundBase)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {

                    // TODO: investigate why using LazyHStack causes the app to freeze with CPU 100% when lifting ForEach contents into a separate view
                    // NOTE: changing LazyHStack -> HStack, moving the ForEach content into a separate view works
                    // LazyHStack {
                    HStack(spacing: 16) {
                        ForEach(accountWalletsViewModel.wallets, id: \.walletId) { wallet in

                            WalletListItem(
                                wallet: wallet,
                                payoutWalletId: payoutWalletViewModel.payoutWalletId
                            )
                            .onTapGesture {
                                navigate(.wallet(wallet))
                            }

                        }
                    }
                    .padding()

                }

                Spacer().frame(height: 16)

                HStack {
                    Text("Account points")
                        .foregroundColor(themeManager.currentTheme.textColor)
                        .font(themeManager.currentTheme.bodyFont)

                    Spacer()
                }
                .padding(.horizontal)
                
                AccountPointsBreakdown(
                    isSeekerOrSagaHolder: isSeekerOrSagaHolder,
                    netPoints: netPoints,
                    payoutPoints: payoutPoints,
                    referralPoints: referralPoints,
                    multiplierPoints: multiplierPoints,
                    reliabilityPoints: reliabilityPoints
                )
                .padding()

                PaymentsList(
                    payments: accountPaymentsViewModel.payments,
                    navigate: navigate
                )

                Spacer()

            }

        }

    }
}

private struct WalletListItem: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var accountPaymentsViewModel: AccountPaymentsViewModel

    var wallet: SdkAccountWallet
    var payoutWalletId: SdkId?

    var body: some View {
        let isPayoutWallet = payoutWalletId?.cmp(wallet.walletId) == 0

        VStack {

            HStack {

                VStack {
                    WalletIcon(blockchain: wallet.blockchain)
                    Spacer()
                }

                Spacer()

                VStack(alignment: .trailing) {

                    PayoutWalletTag(isPayoutWallet: isPayoutWallet)

                    Spacer().frame(height: 8)

                    VStack(spacing: 0) {

                        HStack {

                            Spacer()

                            Text(
                                "\(String(format: "%.2f", accountPaymentsViewModel.totalPaymentsByWalletId(wallet.walletId))) USDC"
                            )
                            .foregroundColor(themeManager.currentTheme.textColor)
                            .font(Font.custom("ABCGravity-ExtraCondensed", size: 24))
                        }

                        HStack {
                            Spacer()

                            Text("total payouts")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                                .padding(.top, -4)
                        }

                    }

                }

            }

            Spacer()

            HStack(alignment: .center) {

                Text(wallet.blockchain)
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)

                Spacer()

                Text("***\(String(wallet.walletAddress.suffix(6)))")
                    .font(Font.custom("PP NeueBit", size: 18))
                    .foregroundColor(themeManager.currentTheme.textColor)

            }
        }
        .padding()
        .frame(width: 240, height: 124)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

}

//#Preview {
//
//    PopulatedWalletsView(
//        navigate: {_ in },
//        isSeekerOrSagaHolder: true,
//        netAccountPoints: 12,
//        presentConnectWalletSheet: .constant(false),
//    )
//}
