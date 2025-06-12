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

    init(api: SdkApi, onSuccess: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self._viewModel = .init(wrappedValue: .init(api: api))
        self.onSuccess = onSuccess
        self.dismiss = dismiss
    }

    var body: some View {
        VStack {

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

            UrTextField(
                text: $viewModel.referralCode,
                label: "Enter network referral code",
                placeholder: "",
                supportingText: viewModel.codeInputSupportingText

            )

            Spacer().frame(height: 8)

            UrButton(
                text: "Update",
                action: {
                    Task {
                        let result = await viewModel.updateReferralNetwork()

                        if case .success = result {
                            onSuccess()
                        }
                    }
                },
                enabled: !viewModel.isUpdatingReferralNetwork,
                isProcessing: viewModel.isUpdatingReferralNetwork,
            )

        }
        .padding(12)
    }
}

//#Preview {
//    UpdateReferralNetworkSheet()
//}
