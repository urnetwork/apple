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
