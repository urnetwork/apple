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
                                    return start + "..." + end
                                }()
                                
                                HStack {
                                    Text(masked)
                                    
                                    Spacer()
                                    
                                    Text("+\(formatBytes(balanceCode.balanceByteCount))")
                                    
                                    Spacer()
        
                                    if let redeemTime = balanceCode.redeemTime {
                                        Text(formatShortDate(unixMilli: redeemTime.unixMilli()))
                                    }
                                    
                                    Spacer()
                                    
                                    if let expiryTime = balanceCode.endTime {
                                        Text(formatShortDate(unixMilli: expiryTime.unixMilli()))
                                    }
                                }
                                .listRowBackground(themeManager.currentTheme.backgroundColor)
                            }
                            
                        } header: {
                            HStack {
                                Text("Code")
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                
                                Spacer()
                                
                                Text("Data")
                                
                                Spacer()
                                
                                Text("Redeemed")
                                    .foregroundStyle(themeManager.currentTheme.textMutedColor)
                                
                                Spacer()
                                
                                Text("Expires")
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
    
    private func formatBytes(_ bytes: Int64) -> String {
        let oneTiB = 1024 * 1024 * 1024 * 1024
        let oneGiB = 1024 * 1024 * 1024
        let doubleBytes = Double(bytes)
        if bytes >= oneTiB {
            let value = doubleBytes / Double(oneTiB)
            return String(format: "%.2f TiB", value)
        } else {
            let value = doubleBytes / Double(oneGiB)
            return String(format: "%.2f GiB", value)
        }
    }
    
    private func formatShortDate(unixMilli: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMilli) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = .current
        return formatter.string(from: date)
    }
    
}

//#Preview {
//    TransferBalanceCodesView(
//        api: MockUrApiService()
//    )
//}
