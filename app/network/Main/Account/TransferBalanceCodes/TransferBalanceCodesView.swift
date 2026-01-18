//
//  TransferBalanceCodesView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/17/26.
//

import SwiftUI

struct TransferBalanceCodesView: View {
    
    @StateObject private var viewModel: ViewModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    let api: UrApiServiceProtocol
    
    init(
        api: UrApiServiceProtocol,
    ) {
        _viewModel = .init(wrappedValue: .init(api: api))
        self.api = api
    }
    
    var body: some View {
        
        ZStack {
        
            if (viewModel.isInitializing) {
                VStack {
                    
                    Spacer()
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                
                List {
                    if (!viewModel.redeemedBalanceCodes.isEmpty) {
                        
                        Section {
                            
                            ForEach(viewModel.redeemedBalanceCodes, id: \.balanceCodeId?.idStr) { balanceCode in
                                let masked: String = {
                                    let keep = 3
                                    guard balanceCode.secret.count > keep * 2 else { return String(repeating: ".", count: max(balanceCode.secret.count, 0)) }
                                    let start = balanceCode.secret.prefix(keep)
                                    let end = balanceCode.secret.suffix(keep)
                                    let middleCount = balanceCode.secret.count - (keep * 2)
                                    return start + String(repeating: ".", count: middleCount) + end
                                }()
                                
                                HStack {
                                    Text(masked)
                                    Spacer()
                                    if let redeemTime = balanceCode.redeemTime {
                                        Text(redeemTime.format("Jan 2, 2006"))
                                    }
                                }
                                .listRowBackground(themeManager.currentTheme.backgroundColor)
                            }
                            
                        } header: {
                            HStack {
                                Text("Code")
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                Spacer()
                                Text("Redeemed")
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                            }
                            .font(themeManager.currentTheme.bodyFont.weight(.semibold))
                            .textCase(nil) // prevent automatic uppercasing in some styles
                            .padding(.vertical, 4)
                        }
                    }
                    
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(themeManager.currentTheme.backgroundColor)
                .refreshable {
                    await viewModel.getRedeemedBalanceCodes()
                }
                .toolbar {
                    
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: {
                            viewModel.displayRedeemSheet = true
                        }) {
                            Image(systemName: "plus")
                        }
                    }
                }
                .sheet(isPresented: $viewModel.displayRedeemSheet) {
                    VStack {
                        
                        RedeemBalanceCodeSheet(
                            closeSheet: {
                                viewModel.displayRedeemSheet = false
                            },
                            onSuccess: {
                                
                                viewModel.displayRedeemSheet = false
                                
                                // start polling
                                subscriptionBalanceViewModel.startPolling()
                                
                                Task {
                                    await viewModel.getRedeemedBalanceCodes()
                                }
                                
                            },
                            api: self.api
                        )
                        
                    }
                    .background(themeManager.currentTheme.backgroundColor)
                }
                
                if (viewModel.redeemedBalanceCodes.isEmpty) {
                    VStack {
                        Text("No balance codes found")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                }
                
            }
            
        }
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
        
    }
}

//#Preview {
//    TransferBalanceCodesView(
//        api: MockUrApiService()
//    )
//}
