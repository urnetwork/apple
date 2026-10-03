//
//  RedeemBalanceCodeSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/9/26.
//

import SwiftUI

struct RedeemBalanceCodeSheet: View {
    
    let closeSheet: () -> Void
    // the code's data is on the balance; a code grants no Pro
    let onSuccess: (RedeemedBalanceCode) -> Void
    @StateObject private var viewModel: ViewModel
    
    @EnvironmentObject var themeManager: ThemeManager
    
    init(
        closeSheet: @escaping () -> Void,
        onSuccess: @escaping (RedeemedBalanceCode) -> Void,
        api: UrApiServiceProtocol
    ) {
        self.closeSheet = closeSheet
        self.onSuccess = onSuccess
        
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            api: api,
        ))
        
    }
    
    var body: some View {
        
        NavigationStack {
        
            VStack {
                
                UrTextField(
                    text: $viewModel.code,
                    label: "Balance code",
                    placeholder: "Enter balance code",
                    supportingText: viewModel.redeemState == .invalid ? "Invalid balance code" : "",
                    isEnabled: viewModel.redeemState != .validating,
                    validationState: viewModel.redeemState,
                    submitLabel: .done,
                    onSubmit: {
                        Task {
                            let result = await viewModel.redeem()
                            self.handleResult(result)
                        }
                    }
                )

                /**
                 * Someone opening this sheet with no code needs to know where to get
                 * one. Without this the sheet asks for a code and offers no way to
                 * obtain one — a dead end.
                 *
                 * Deliberately PLAIN TEXT: no link, no button. App Store rules forbid
                 * steering a user to an external purchase, but nothing stops us saying
                 * where codes come from.
                 */
                Text("Don't have a code? Data codes can be purchased at ur.io and emailed to you.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)

                Spacer()

            }
            .padding()
            .toolbar {
                
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        "Redeem",
                        action: {
                            Task {
                                let result = await viewModel.redeem()
                                self.handleResult(result)
                            }
                        },
                        
                    )
                    .disabled(viewModel.redeemState == .validating || viewModel.code.count != 26)
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: {
                        closeSheet()
                    }) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .navigationTitle("Redeem Code")
            
        }
        .presentationDetents([.height(272)])
        
    }
    
    private func handleResult(_ result: Result<RedeemedBalanceCode, Error>) {
        print("RedeemBalanceCode handleResult")
        switch result {
            
        case .success(let redeemed):

            onSuccess(redeemed)
            
            break
        case .failure(let error):
            print("CreateNetworkView: handleResult: \(error.localizedDescription)")
            break
            
        }
    }
    
}

//#Preview {
//    RedeemBalanceCodeSheet()
//}
