//
//  UpdateReferralNetworkSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 6/12/25.
//

import SwiftUI
import URnetworkSdk

struct UpdateReferralNetworkSheet: View {

    @EnvironmentObject var themeManager: ThemeManager
    @StateObject private var viewModel: ViewModel

    var onSuccess: () -> Void
    var dismiss: () -> Void
    var referralNetwork: SdkReferralNetwork?

    init(
        api: UrApiServiceProtocol,
        onSuccess: @escaping () -> Void,
        dismiss: @escaping () -> Void,
        referralNetwork: SdkReferralNetwork?
    ) {
        self._viewModel = .init(wrappedValue: .init(api: api))
        self.onSuccess = onSuccess
        self.dismiss = dismiss
        self.referralNetwork = referralNetwork
    }

    var body: some View {
        VStack {

            Spacer().frame(height: 24)

            HStack {
                Text("Update referral network")
                    .font(themeManager.currentTheme.toolbarTitleFont)

                Spacer()

                #if os(macOS)
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                #endif

            }

            Spacer().frame(height: 8)

            HStack {
                UrTextField(
                    text: $viewModel.referralCode,
                    label: "Enter network referral code",
                    placeholder: "",
                    supportingText: viewModel.codeInputSupportingText

                )

                Button(
                    "Update",
                    action: {
                        Task {
                            let result = await viewModel.updateReferralNetwork()

                            if case .success = result {
                                onSuccess()
                            }
                        }
                    },
                )
                .disabled(viewModel.isUpdatingReferralNetwork || viewModel.referralCode.count < 6)
            }

            if referralNetwork != nil {

                Spacer().frame(height: 18)

                HStack {
                    Text("Unlink referral network")
                        .font(themeManager.currentTheme.toolbarTitleFont)

                    Spacer()
                }

                Spacer().frame(height: 8)

                HStack(alignment: .bottom) {

                    VStack {
                        HStack {
                            UrLabel(text: "Current referral network")
                            Spacer()
                        }

                        HStack {
                            Text(referralNetwork?.name ?? "Something went wrong")
                                .font(themeManager.currentTheme.bodyFont)
                            Spacer()
                        }
                    }

                    HStack {
                        Spacer()
                        Button(
                            "Unlink",
                            role: .destructive
                        ) {
                            viewModel.unlinkAlertVisible = true
                        }
                        .alert(
                            "Unlink referral network",
                            isPresented: $viewModel.unlinkAlertVisible,
                            actions: {
                                Button(role: .destructive) {

                                    Task {
                                        let result = await viewModel.unlinkReferralNetwork()

                                        if case .success = result {
                                            viewModel.unlinkAlertVisible = false
                                            onSuccess()
                                        }
                                    }

                                } label: {
                                    Text("Unlink")
                                }

                                Button("Cancel", role: .cancel) {
                                    viewModel.unlinkAlertVisible = false
                                }
                            },
                            message: {
                                Text(
                                    "When unlinking your referral network, you will no longer be able to earn points from \(referralNetwork?.name ?? "the referral network")."
                                )
                            }
                        )
                    }

                }

            }

            Spacer()

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
    }
}

//#Preview {
//    UpdateReferralNetworkSheet()
//}
