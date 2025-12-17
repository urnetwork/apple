//
//  AccountView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/13.
//

import SwiftUI
import URnetworkSdk

struct AccountRootView: View {
    
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @EnvironmentObject var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @EnvironmentObject var subscriptionManager: AppStoreSubscriptionManager
    @EnvironmentObject var connectViewModel: ConnectViewModel
    
    let navigate: (AccountNavigationPath) -> Void
    let logout: () -> Void
    let api: SdkApi
    let networkName: String?
    let meanReliabilityWeight: Double
    let isPro: Bool
    
    @StateObject private var viewModel: ViewModel = ViewModel()
    
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    @ObservedObject var accountPaymentsViewModel: AccountPaymentsViewModel
    
    private let urnetworkAppStoreID = "6741000606"
    
    private func appStoreWriteReviewURL(appID: String) -> URL? {
        #if os(iOS)
        // Opens App Store app directly on iOS
        return URL(string: "itms-apps://itunes.apple.com/app/id\(appID)?action=write-review")
        #elseif os(macOS)
        // Opens Mac App Store directly on macOS
        return URL(string: "macappstore://itunes.apple.com/app/id\(appID)?action=write-review")
        #else
        return nil
        #endif
    }
    
    init(
        navigate: @escaping (AccountNavigationPath) -> Void,
        logout: @escaping () -> Void,
        api: SdkApi,
        referralLinkViewModel: ReferralLinkViewModel,
        accountPaymentsViewModel: AccountPaymentsViewModel,
        networkName: String?,
        meanReliabilityWeight: Double,
        isPro: Bool
    ) {
        self.navigate = navigate
        self.logout = logout
        self.api = api
        
        self.referralLinkViewModel = referralLinkViewModel
        self.accountPaymentsViewModel = accountPaymentsViewModel
        self.networkName = networkName
        self.meanReliabilityWeight = meanReliabilityWeight
        self.isPro = isPro
    }
    
    
    var body: some View {
        
        let isGuest = deviceManager.parsedJwt?.guestMode ?? true

        ScrollView {
            
            HStack {
                
                Spacer(minLength: 0)
             
                VStack {
                    
//                    Spacer().frame(height: 16)
                 
                    VStack(alignment: .leading, spacing: 0) {
                        
                        Text("Plan")
                            .font(themeManager.currentTheme.secondaryBodyFont)
                            .foregroundColor(themeManager.currentTheme.textMutedColor)
                        
                        HStack(alignment: .firstTextBaseline) {
                            
                            if (isGuest) {
                                Text("Guest")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                            } else {
                             
                                Text(isPro ? "Free" : "Supporter")
                                    .font(themeManager.currentTheme.titleCondensedFont)
                                    .foregroundColor(themeManager.currentTheme.textColor)
                                
                            }
                            
                            Spacer()
          
                            /**
                             * Upgrade subscription button
                             * if user is
                             */
                            if (!isPro && !isGuest) {
                             
                                Button(action: {
                                    viewModel.isPresentedUpgradeSheet = true
                                }) {
                                    Text("Upgrade")
                                        .font(themeManager.currentTheme.secondaryBodyFont)
                                }
                                
                            }
                            
                        }
                        
                        Spacer().frame(height: 8)
                        
                        if (!isPro) {
                            /**
                             * only display usage bar to users with basic plans
                             */
                            
                            UsageBar(
                                availableByteCount: subscriptionBalanceViewModel.availableByteCount,
                                pendingByteCount: subscriptionBalanceViewModel.pendingByteCount,
                                usedByteCount: subscriptionBalanceViewModel.usedBalanceByteCount,
                                meanReliabilityWeight: meanReliabilityWeight,
                                totalReferrals: referralLinkViewModel.totalReferrals
                            )
                            
                        }
                        
                        Divider()
                            .background(themeManager.currentTheme.borderBaseColor)
                            .padding(.vertical, 16)
                        
                        HStack {
                            Text("Network earnings")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                            Spacer()
                        }
                        
                        HStack(alignment: .firstTextBaseline) {
                            
                            let totalPayouts = accountPaymentsViewModel.totalPayoutsUsdc
                            
                            Text(totalPayouts > 0 ? String(format: "%.4f", totalPayouts) : "0")
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                            Text("USDC")
                                .font(themeManager.currentTheme.secondaryBodyFont)
                                .foregroundColor(themeManager.currentTheme.textMutedColor)
                            
                            Spacer()
                            
                        }
                        
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(12)
                    .padding()
//                    .padding(.horizontal)
                    
//                    Spacer().frame(height: 16)
                    
                    /**
                     * Navigation items
                     */
                    VStack(spacing: 0) {
                        AccountNavLink(
                            name: "Profile",
                            iconPath: "ur.symbols.user.circle",
                            action: {
                                
                                if isGuest {
                                    viewModel.isPresentedCreateAccount = true
                                } else {
                                    navigate(.profile)
                                }
                                
                            }
                        )
                        AccountNavLink(
                            name: "Settings",
                            iconPath: "ur.symbols.sliders",
                            action: {
                                if isGuest {
                                    viewModel.isPresentedCreateAccount = true
                                } else {
                                    navigate(.settings)
                                }
                            }
                        )
                        AccountNavLink(
                            name: "Wallet",
                            iconPath: "ur.symbols.wallet",
                            action: {
                                if isGuest {
                                    viewModel.isPresentedCreateAccount = true
                                } else {
                                    navigate(.wallets)
                                }
                            }
                        )
                        
                        ReferralShareLink(referralLinkViewModel: referralLinkViewModel) {
                            
                            VStack(spacing: 0) {
                                HStack {
                                    
                                    Image("ur.symbols.heart")
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                    
                                    Spacer().frame(width: 16)
                                    
                                    Text("Refer friends")
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)
                                    
                                    Spacer()
                                    
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                
                                Divider()
                                    .background(themeManager.currentTheme.borderBaseColor)
                                
                            }
                            
                        }
                        
                        /**
                         * Review
                         */
                        Button(action: {
                            if let url = appStoreWriteReviewURL(appID: urnetworkAppStoreID) {
                                openURL(url)
                            }
                        }) {
                            
                            VStack(spacing: 0) {
                                HStack {
                                    
                                    Image(systemName: "pencil")
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        .frame(width: 24)
                                    
                                    Spacer().frame(width: 16)
                                    
                                    Text("Review URnetwork")
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)
                                    
                                    Spacer()
                                    
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                
                                Divider()
                                    .background(themeManager.currentTheme.borderBaseColor)
                                
                            }
                            .contentShape(Rectangle())
                            
                        }
                        .buttonStyle(.plain)
                        
                        /**
                         * Check IP
                         */
                        Button(action: {
                            if let url = URL(string: "https://ur.io/ip") {
                                
                                #if canImport(UIKit)
                                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                #endif
                                
                                #if canImport(AppKit)
                                NSWorkspace.shared.open(url)
                                #endif
                                
                            }
                        }) {
                            
                            VStack(spacing: 0) {
                                HStack {
                                    
                                    Image(systemName: "dot.scope")
                                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                                        .frame(width: 24)
                                    
                                    Spacer().frame(width: 16)
                                    
                                    Text("Check my IP")
                                        .font(themeManager.currentTheme.bodyFont)
                                        .foregroundColor(themeManager.currentTheme.textColor)
                                    
                                    Spacer()
                                    
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal)
                                
                                Divider()
                                    .background(themeManager.currentTheme.borderBaseColor)
                                
                            }
                            .contentShape(Rectangle())
                            
                        }
                        .buttonStyle(.plain)
                        
                        /**
                         * URnode Carousel
                         */
                        URNodeCarousel()
                        
                        Spacer().frame(height: 16)
                    }
                    
                    Spacer()
                    
                    if isGuest {
                        UrButton(
                            text: "Create an account",
                            action: {
                                viewModel.isPresentedCreateAccount = true
                            }
                        )
                    }
                    
                }
                .frame(maxWidth: 600)
                
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            
        }
        .refreshable {
            await subscriptionBalanceViewModel.fetchSubscriptionBalance()
        }
//        .padding()
//        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task {
                await subscriptionBalanceViewModel.fetchSubscriptionBalance()
            }
        }
        .sheet(isPresented: $viewModel.isPresentedUpgradeSheet) {
            UpgradeSubscriptionSheet(
                monthlyProduct: subscriptionManager.monthlySubscription,
                yearlyProduct: subscriptionManager.yearlySubscription,
                purchase: { product in
                    
                    let initiallyConnected = deviceManager.device?.getConnected() ?? false
                    
                    #if os(macOS)
                    if (initiallyConnected) {
                        connectViewModel.disconnect()
                    }
                    #endif
                    
                    Task {
                        do {
                            try await subscriptionManager.purchase(
                                product: product,
                                onSuccess: {
                                    subscriptionBalanceViewModel.startPolling()
                                    // subscriptionBalanceViewModel.setCurrentPlan(.supporter)
                                }
                            )
    
                        } catch(let error) {
                            print("error making purchase: \(error)")
                        }
                        
                        #if os(macOS)
                        if (initiallyConnected) {
                            connectViewModel.connect()
                        }
                        #endif

                    }

                },
                isPurchasing: subscriptionManager.isPurchasing,
                purchaseSuccess: subscriptionManager.purchaseSuccess,
                dismiss: {
                    viewModel.isPresentedUpgradeSheet = false
                }
            )
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $viewModel.isPresentedCreateAccount) {
            LoginNavigationView(
                api: api,
                cancel: {
                    viewModel.isPresentedCreateAccount = false
                },
                
                handleSuccess: { jwt in
                    Task {
                        // viewModel.isPresentedCreateAccount = false
                        await handleSuccessWithJwt(jwt)
                    }
                }
            )
        }
        .toolbar {
            ToolbarItem {
                AccountMenu(
                    isGuest: isGuest,
                    logout: logout,
                    networkName: networkName,
                    isPresentedCreateAccount: $viewModel.isPresentedCreateAccount,
                    referralLinkViewModel: referralLinkViewModel
                )
            }
        }
        #endif
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    Task {
                        await accountPaymentsViewModel.fetchPayments()
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(accountPaymentsViewModel.isLoadingPayments)
            }
        }
        #endif
    }
    
    private func handleSuccessWithJwt(_ jwt: String) async {
        
        do {
            
            deviceManager.logout()
            
            try await deviceManager.waitUntilDeviceUninitialized()
            
            await deviceManager.initializeNetworkSpace()
            
            try await deviceManager.waitUntilDeviceInitialized()
            
            let result = await deviceManager.authenticateNetworkClient(jwt)
            
            if case .failure(let error) = result {
                print("[AccountRootView] handleSuccessWithJwt: \(error.localizedDescription)")
                
                snackbarManager.showSnackbar(message: "There was an error creating your network. Please try again later.")
                
                return
            }
            
            // TODO: fade out login flow
            // TODO: create navigation view model and switch to main app instead of checking deviceManager.device
            
        } catch {
            print("handleSuccessWithJwt error is \(error)")
        }

        
    }
    
}

private struct AccountNavLink: View {
    
    var name: LocalizedStringKey
    var iconPath: String
    var action: () -> Void
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        Button(action: action) {
            
            VStack(spacing: 0) {
                HStack {
                    
                    Image(iconPath)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    
                    Spacer().frame(width: 16)
                    
                    Text(name)
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textColor)
                    
                    Spacer()
                    
                    Image("ur.symbols.caret.right")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                    
                }
                .padding(.vertical, 8)
                .padding(.horizontal)
                
                Divider()
                    .background(themeManager.currentTheme.borderBaseColor)
                
            }
            .contentShape(Rectangle())
            
        }
        .buttonStyle(.plain)
        // .contentShape(Rectangle())
        
    }
}

//#Preview {
//    
//    let themeManager = ThemeManager.shared
//    
//    VStack {
//        AccountRootView(
//            navigate: {_ in},
//            logout: {},
//            api: SdkBringYourApi()
//        )
//    }
//    .environmentObject(themeManager)
//    .background(themeManager.currentTheme.backgroundColor)
//    .frame(maxHeight: .infinity)
//    
//}
