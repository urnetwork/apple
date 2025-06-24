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

                VStack(spacing: 0) {

                    HStack {
                        Text("Points breakdown")
                            .font(themeManager.currentTheme.toolbarTitleFont)
                        Spacer()
                    }

                    Spacer().frame(height: 12)

                    HStack {

                        VStack {
                            HStack {
                                UrLabel(text: "Payout")
                                Spacer()
                            }

                            HStack {
                                Text(payoutPoints.formatted(.number.grouping(.automatic)))
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                Spacer()
                            }
                        }

                        Spacer()

                        VStack {
                            HStack {
                                UrLabel(text: "Referral")
                                Spacer()
                            }

                            HStack {
                                Text(referralPoints.formatted(.number.grouping(.automatic)))
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                Spacer()
                            }
                        }
                        
                        Spacer()
                        
                        VStack {
                            HStack {
                                UrLabel(text: "Reliability")
                                Spacer()
                            }

                            HStack {
                                Text("0")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)

                                Spacer()
                            }
                        }

                    }

                    Spacer().frame(height: 8)

                    Divider()

                    Spacer().frame(height: 16)
                    
                    if isSeekerOrSagaHolder {
                        
                        VStack(spacing: 0) {
                         
                            HStack(alignment: .center) {

                                Image("2x")
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 32, height: 32)

                                Spacer().frame(width: 16)

                                VStack(alignment: .leading) {
                                    
                                    Text("Seeker Token Verified!")
                                        .font(themeManager.currentTheme.bodyFont)
                                    
                                    Text("You're earning 2x points")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    
                                }

                                Spacer()
                                
                                VStack(alignment: .trailing, spacing: 0) {
                                 
                                    Text("+\(multiplierPoints.formatted(.number.grouping(.automatic)))")
                                        .font(themeManager.currentTheme.titleCondensedFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)

                                }
                                
                            }
             
                        }
                        
                        Spacer().frame(height: 16)

                    }

                    HStack {
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 0) {
                         
                            Text(netPoints.formatted(.number.grouping(.automatic)))
                                .font(Font.custom("ABCGravity-ExtraCondensed", size: 42))
                                // .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                                .padding(.bottom, -4)
                                
                            Text("Net points earned")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                
                            
                        }
                        
                    }

                }
                .padding()
                .background(themeManager.currentTheme.tintedBackgroundBase)
                .cornerRadius(12)
                .padding()

                PaymentsList(
                    payments: accountPaymentsViewModel.payments,
                    navigate: navigate
                )
                .padding()

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
