//
//  ReferralsView.swift
//  URnetwork
//
//  Account › Referrals ("Refer and earn"). Everything about referring lives
//  here, top to bottom: the gold king-frog panel (the code, share, the
//  progress toward the code's cap and the crown once a friend has joined), the
//  totals (friends joined, points from referrals), and the referral network
//  this network signed up with. The order matches the Android screen. It used
//  to be spread over the account root (a refer sheet), Settings (code +
//  referral network) and Earnings.
//

import SwiftUI
import URnetworkSdk

struct ReferralsView: View {

    @EnvironmentObject var themeManager: ThemeManager

    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    @ObservedObject var accountPointsStore: AccountPointsStore
    @StateObject private var viewModel: ViewModel

    let api: UrApiServiceProtocol

    init(
        api: UrApiServiceProtocol,
        referralLinkViewModel: ReferralLinkViewModel,
        accountPointsStore: AccountPointsStore
    ) {
        self.api = api
        self.referralLinkViewModel = referralLinkViewModel
        self.accountPointsStore = accountPointsStore
        _viewModel = StateObject(wrappedValue: ViewModel(api: api))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                referralCard

                statsCard

                referralNetworkCard
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
            .tabletReadableColumn()
        }
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
        }
        .sheet(isPresented: $viewModel.presentUpdateReferralNetworkSheet) {
            UpdateReferralNetworkSheet(
                api: api,
                onSuccess: {
                    Task {
                        await viewModel.fetchReferralNetwork()
                    }
                    viewModel.presentUpdateReferralNetworkSheet = false
                },
                dismiss: {
                    viewModel.presentUpdateReferralNetworkSheet = false
                },
                referralNetwork: viewModel.referralNetwork
            )
            .environmentObject(themeManager)
            #if os(iOS)
            .presentationDetents([.height(268)])
            .presentationDragIndicator(.visible)
            #endif
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    Task {
                        await refresh()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading || referralLinkViewModel.isLoading)
            }
        }
        #endif
    }

    /**
     * The gold king-frog panel with the code, share, the progress bar toward
     * the code's cap and the crown once a friend has joined, exactly as the
     * Android screen shows it. The bonus figures come from the server's
     * referral terms, never a literal.
     */
    private var referralCard: some View {
        ReferralGoldPanel(
            referralCode: referralLinkViewModel.referralCode ?? "",
            totalReferrals: referralLinkViewModel.totalReferrals,
            terms: referralLinkViewModel.terms
        )
    }

    /**
     * Friends joined (paid up to the cap) and the points referrals earned.
     */
    private var statsCard: some View {

        let totalReferrals = referralLinkViewModel.totalReferrals
        let terms = referralLinkViewModel.terms

        return VStack(alignment: .leading, spacing: 0) {

            HStack(alignment: .firstTextBaseline) {
                UrLabel(text: "Total referrals")

                Spacer()

                Text(verbatim: "\(totalReferrals)/\(terms.maxReferrals)")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
            }

            Spacer().frame(height: 4)

            Text(verbatim: "\(totalReferrals)")
                .font(themeManager.currentTheme.titleCondensedFont)
                .foregroundColor(themeManager.currentTheme.textColor)

            Divider()
                .background(themeManager.currentTheme.borderBaseColor)
                .padding(.vertical, 16)

            HStack {
                UrLabel(text: "Points earned")
                Spacer()
            }

            Spacer().frame(height: 4)

            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: SnAlpha.formatPoints(accountPointsStore.referralPoints))
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                Spacer()

                UrLabel(text: "Referral")
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    /**
     * The referral network this network signed up with, and the editor to
     * link or unlink one (moved here from Settings).
     */
    private var referralNetworkCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack {
                UrLabel(text: "Referral network")
                Spacer()
            }

            Spacer().frame(height: 8)

            HStack {
                if let name = viewModel.referralNetwork?.name, !name.isEmpty {
                    Text(name)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                } else {
                    Text("None")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }

                Spacer()

                Button(action: {
                    viewModel.presentUpdateReferralNetworkSheet = true
                }) {
                    Text("Update")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(12)
    }

    private func refresh() async {
        async let network: Void = viewModel.fetchReferralNetwork()
        async let link: Void = referralLinkViewModel.fetchReferralLink()
        async let points: Void = accountPointsStore.fetchAccountPoints()
        (_, _, _) = await (network, link, points)
    }
}
