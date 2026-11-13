//
//  TransferBalanceCodesView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 1/17/26.
//

import SwiftUI
import URnetworkSdk

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
                                    
                                    Text(Self.amountText(balanceCode))
                                    
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
                .sheetOffTheFold(isPresented: $viewModel.displayRedeemSheet) {
                    VStack {
                        
                        RedeemBalanceCodeSheet(
                            closeSheet: {
                                viewModel.displayRedeemSheet = false
                            },
                            onSuccess: { redeemed in
                                
                                viewModel.displayRedeemSheet = false
                                
                                // the balance and the plan, read once: a gift
                                // code's year of Pro reaches the plan and the jwt
                                // from here. Never the purchase confirmation
                                // poll: the redeem itself granted.
                                Task { await subscriptionBalanceViewModel.fetchSubscriptionBalance() }
                                
                                Task {
                                    await viewModel.getRedeemedBalanceCodes()
                                }
                                
                                // confirmed as every redeem is
                                // (BalanceCodeRedeemedView), besides its new row
                                Task {
                                    // Wait approx. 300ms for the sheet to animate out and keyboard to dismiss
                                    try? await Task.sleep(for: .milliseconds(300))
                                    viewModel.redeemedBalanceCode = redeemed
                                    viewModel.balanceCodeRedeemed = true
                                }
                                
                            },
                            api: self.api
                        )
                        .environmentObject(themeManager)
                        
                    }
                    .background(themeManager.currentTheme.backgroundColor)
                }
                .sheetOffTheFold(isPresented: $viewModel.balanceCodeRedeemed) {
                    BalanceCodeRedeemedView(redeemed: viewModel.redeemedBalanceCode, dismiss: {
                        viewModel.balanceCodeRedeemed = false
                    })
                    .environmentObject(themeManager)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea()
                }
                
                if let loadErrorMessage = viewModel.loadErrorMessage {
                    VStack {
                        Text(loadErrorMessage)
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                } else if (viewModel.redeemedBalanceCodes.isEmpty) {
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
    
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        formatter.locale = .current
        return formatter
    }()

    private func formatShortDate(unixMilli: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMilli) / 1000)
        return Self.shortDateFormatter.string(from: date)
    }
    
    /// A row's amount: a gift code's year of Pro in place of its 0 bytes
    /// (mmm/GIFTOFPRIVACY.md 10.5), or the data a data code added. A code
    /// from a server that predates gift codes reads as data.
    static func amountText(_ balanceCode: SdkRedeemedBalanceCode) -> String {
        if balanceCode.kind == SdkBalanceCodeKindProGift {
            return String(localized: "A year of Pro")
        }
        let amount = formatBalanceBytes(Int(balanceCode.balanceByteCount))
        return String(localized: "+\(amount)")
    }

}

//#Preview {
//    TransferBalanceCodesView(
//        api: MockUrApiService()
//    )
//}
