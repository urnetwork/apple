//
//  RedeemBalanceCodeSheet.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/9/26.
//

import SwiftUI

struct RedeemBalanceCodeSheet: View {
    
    let closeSheet: () -> Void
    let onSuccess: () -> Void
    @StateObject private var viewModel: ViewModel
    
    @EnvironmentObject var themeManager: ThemeManager
//    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    
    init(
        closeSheet: @escaping () -> Void,
        onSuccess: @escaping () -> Void,
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
                
//                Spacer().frame(height: 16)
                
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
  
                Spacer().frame(height: 32)
                
                // for testing - HFAEFVM7GAWSDV3JIHUFJEMLB2
                
                UrButton(
                    text: "Redeem",
                    action: {
                        Task {
                            let result = await viewModel.redeem()
                            self.handleResult(result)
                        }
                    },
                    enabled: viewModel.redeemState != .validating && viewModel.code.count == 26,
                    isProcessing: viewModel.redeemState == .validating
                )
                
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Redeem Balance Code")
                        .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        closeSheet()
                    }) {
                        Image(systemName: "xmark")
                    }
                }
            }
            
        }
        .presentationDetents([.height(272)])
        
    }
    
    private func handleResult(_ result: Result<Void, Error>) {
        print("RedeemBalanceCode handleResult")
        switch result {
            
        case .success:

//            closeSheet()
//            
//            // start polling
//            subscriptionBalanceViewModel.startPolling()
            
            onSuccess()
            
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
