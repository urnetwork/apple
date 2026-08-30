//
//  MainView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2025/01/07.
//

import SwiftUI
import URnetworkSdk

struct MainView: View {
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let device: SdkDeviceRemote
    let logout: () -> Void
    // var connectViewController: SdkConnectViewController?
    let welcomeAnimationComplete: Binding<Bool>
    let introductionComplete: Binding<Bool>
    let isPro: Bool
    
    @StateObject private var subscriptionBalanceViewModel: SubscriptionBalanceViewModel
    @StateObject private var subscriptionManager: AppStoreSubscriptionManager
    @StateObject private var providerListStore: ProviderListStore
    @ObservedObject private var transactionMonitor = AppStoreTransactionMonitor.shared
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @Environment(\.presentationActive) private var presentationActive
    
    init(
        api: SdkApi,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        welcomeAnimationComplete: Binding<Bool>,
        networkId: SdkId?,
        introductionComplete: Binding<Bool>,
        isPro: Bool
    ) {
        self.api = api
        self.logout = logout
        self.device = device
        let urApiService = UrApiService(api: api)
        self.urApiService = urApiService
        self.welcomeAnimationComplete = welcomeAnimationComplete
        self.introductionComplete = introductionComplete
        _subscriptionBalanceViewModel = StateObject(
            wrappedValue: SubscriptionBalanceViewModel(
                urApiService: urApiService,
                isPro: isPro,
                refreshJwt: {
                    do {
                        print("trying to refresh JWT")
                        try device.refreshToken(0)
                    } catch {
                        print("error refreshing token: \(error)")
                    }
                }
            )
            
        )
        self.isPro = isPro
        _subscriptionManager = StateObject(wrappedValue: AppStoreSubscriptionManager(networkId: networkId))
        _providerListStore = StateObject(wrappedValue: ProviderListStore(urApiService: urApiService))
    }
    
    var body: some View {
        
        Group {
         
            switch welcomeAnimationComplete.wrappedValue {
                case false:
                    WelcomeAnimation(
                        welcomeAnimationComplete: self.welcomeAnimationComplete,
                        subscriptionBalanceLoading: self.subscriptionBalanceViewModel.isLoading
                    )
                case true:
                
                    #if os(iOS)
                    MainTabView(
                        api: api,
                        urApiService: urApiService,
                        device: device,
                        logout: self.logout,
                        providerStore: providerListStore,
                        introductionComplete: introductionComplete,
                    //                            currentPlan: subscriptionBalanceViewModel.currentPlan,
                        errorFetchingSubscriptionBalance: subscriptionBalanceViewModel.errorFetchingSubscriptionBalance,
                        isPro: isPro
                    )
                    #elseif os(macOS)
                    MainNavigationSplitView(
                        api: api,
                        urApiService: urApiService,
                        device: device,
                        logout: self.logout,
                        providerListStore: providerListStore,
                        introductionComplete: introductionComplete,
                        isPro: isPro
                    )
                    #endif
                
            }
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.backgroundColor)
        .environmentObject(subscriptionBalanceViewModel)
        .environmentObject(subscriptionManager)
        .onAppear {
            subscriptionBalanceViewModel.setActive(presentationActive)

            /**
             * Catch-up for transactions that arrived BEFORE this view existed:
             * the process-scoped AppStoreTransactionMonitor reports (and, on a
             * terminal server answer, finishes) transactions from launch, and
             * the manager's init replays the monitor's state through its
             * per-network gate. If a matching transaction was already credited
             * (e.g. an Ask to Buy approval or a cross-device purchase
             * delivered while logged out), the sequence is already non-zero
             * here — and onChange below will never fire for it. Start the
             * confirmation poll now.
             */
            if 0 < subscriptionManager.transactionUpdateSequence {
                subscriptionBalanceViewModel.startPolling()
            }
        }
        .onChange(of: presentationActive) { active in
            subscriptionBalanceViewModel.setActive(active)
        }
        .onDisappear {
            subscriptionBalanceViewModel.setActive(false)
        }
        .onChange(of: subscriptionManager.transactionUpdateSequence) { _ in
            /**
             * StoreKit delivered a transaction outside of an in-app purchase flow: an
             * Ask to Buy approval that came through later, a purchase made on another
             * device, a renewal — anything that completed while the app was closed.
             *
             * This used to do NOTHING. The transaction listener starts at init, but the
             * callback it invoked (`onPurchaseSuccess`) is only assigned inside
             * `purchase()`. So on a fresh launch it was nil: StoreKit handed us the
             * transaction, we finished it, and the app never noticed. The user's purchase
             * had completed and they were still on the free plan, with nothing to explain
             * why.
             *
             * Poll: the server learns of the purchase by webhook, so give it a moment and
             * pick up the entitlement.
             */
            subscriptionBalanceViewModel.startPolling()
        }
        .onChange(of: deviceManager.isPro) { newValue in
            /**
             * plan updates change subscription balance polling behavior
             */
            subscriptionBalanceViewModel.updateIsPro(newValue)
        }
        .onChange(of: transactionMonitor.wrongNetworkSequence) { _ in
            /**
             * A delivered transaction reported `wrong_network`: it is real and
             * was finished (the network it was purchased under gets its credit
             * via the webhook/reconciler), but it belongs to a DIFFERENT
             * network than this session. It must not start this network's
             * poll — but it must not vanish silently either.
             */
            snackbarManager.showSnackbar(message: String(localized: "Your subscription was purchased under a different account. Log in to that account to use it."))
        }
        .onChange(of: subscriptionBalanceViewModel.purchaseConfirmationTimedOut) { timedOut in
            /**
             * The confirmation poll gave up without the server confirming the
             * purchase (finding A2). The upgrade sheet shows this state when it
             * is still open — but the user may have dismissed it minutes ago,
             * so also surface it on the app's global overlay. The purchase is
             * still likely to land: the background poll and the next launch
             * pick it up.
             */
            if timedOut {
                snackbarManager.showSnackbar(message: String(localized: "We couldn't confirm your purchase yet. If you completed checkout, your plan will update automatically in a few minutes — there's no need to buy again."))
            }
        }
        .onChange(of: subscriptionBalanceViewModel.didDetectUpgradeToPro) { detected in
            if detected {
                // at the free -> paid upgrade, reset provide mode to never;
                // the user can opt back in afterward and that choice persists
                deviceManager.provideControlMode = .Never
            }
        }
    }
}

struct ErrorLoadingSubscriptionBalanceView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    
    let reload: () -> Void
    let isLoading: Bool
    
    var body: some View {
        
        NavigationStack {
            
            VStack(alignment: .leading) {
                
                HStack(alignment: .center) {
                 
                    Image("ur.symbols.unstable")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64)
                        .clipped()
                    
                }
                .frame(maxWidth: .infinity)
                
                Spacer().frame(height: 64)
                
                Text(
                    "Error loading your account plan."
                )
                .font(themeManager.currentTheme.secondaryTitleFont)
                
                
                Text("Please try again.")
                    .font(themeManager.currentTheme.bodyFont)
                
                Spacer().frame(height: 16)
                
                UrButton(
                    text: "Retry",
                    action: reload,
                    enabled: !isLoading,
                    isProcessing: isLoading
                )
                
                Spacer().frame(height: 8)
                
                Text("If the problem persists, contact us at [support@ur.io](mailto:support@ur.io) or [join our Discord](https://discord.com/invite/RUNZXMwPRK) for direct support.")
                    .font(themeManager.currentTheme.secondaryBodyFont)
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.backgroundColor)
            
        }

    }
    
}

struct WelcomeAnimation: View {
    
    @Binding var welcomeAnimationComplete: Bool
    let subscriptionBalanceLoading: Bool
    
    
    @State private var opacity: Double = 1
    @EnvironmentObject var themeManager: ThemeManager
    
    @State private var globeSize: CGFloat = 256
    @State private var welcomeOffset: CGFloat = 400
    @State private var backgroundOpacity: Double = 0
    
    var body: some View {
        
        GeometryReader { geometry in
            
            let size = geometry.size
         
            ZStack {
                
                Image("OnboardingBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, minHeight: 0)
                    .ignoresSafeArea()
                    .opacity(backgroundOpacity)
                
                VStack(spacing: -2) {
                    
                    // top overlay
                    Rectangle()
                        .fill(.urBlack)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                    
                    
                    VStack(spacing: -2) {
                        
                        HStack(spacing: -2) {
                            // left overlay
                            Rectangle()
                                .fill(.urBlack)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            
                            // mask
                            Image("GlobeMask")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: globeSize + 2, height: globeSize + 2)
                                .offset(x: -1, y: -1)
                            
                            // right overlay
                            Rectangle()
                                .fill(.urBlack)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        
                    }
                    .frame(maxWidth: .infinity, maxHeight: globeSize)
                    
                    // bottom overlay
                    Rectangle()
                        .fill(.urBlack)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .bottom)
                    
                    
                }
                .position(x: size.width / 2, y: size.height / 2)

                // Welcome message overlay
                VStack {
                    
                    Spacer()
                 
                    VStack {
                        
                        HStack {
                            Image("ur.symbols.globe")
                            Spacer()
                        }
                        
                        HStack {
                            Text("Nicely done.")
                                .font(themeManager.currentTheme.titleCondensedFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            
                            Spacer()
                        }
                        
                        HStack {
                            Text("Step into the internet as it should be.")
                                .font(themeManager.currentTheme.titleFont)
                                .foregroundColor(themeManager.currentTheme.inverseTextColor)
                            
                            Spacer()
                        }
                        
                        UrButton(
                            text: "Enter",
                            action: {
                                handleExit()
                            },
                            style: .outlinePrimary,
                            enabled: !subscriptionBalanceLoading,
                            isProcessing: subscriptionBalanceLoading,
                        )
                        .accessibilityIdentifier("acceptance.welcome.enter")
                        
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.urLightYellow)
                    .cornerRadius(12)
                    .padding()
                    
                }
                .frame(maxWidth: 400)
                .offset(y: welcomeOffset) // Apply the offset to move the VStack offscreen
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        withAnimation(.easeInOut) {
                            welcomeOffset = 0 // Slide the VStack up onscreen
                        }
                    }
                }
                
            }
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .opacity(opacity)
            .onAppear {
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation(.easeIn) {
                        backgroundOpacity = 1
                    }
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    expandMask(size: size)
                }
                
            }
            
        }
        
    }
    
    private func expandMask(size: CGSize) {
        let targetSize = max(size.width, size.height) * 1.5 // ensure the mask is larger than the screen
        withAnimation(.easeInOut(duration: 2.0)) {
            globeSize = targetSize
        }
    }
    
    private func handleExit() {
        

        withAnimation(.easeInOut) {
            welcomeOffset = 400
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeOut(duration: 1.0)) {
                opacity = 0.0
            }
            
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            welcomeAnimationComplete = true
        }
        
    }
    
}

#Preview {
    
    let themeManager = ThemeManager.shared
    
    VStack {
        WelcomeAnimation(
            welcomeAnimationComplete: .constant(false),
            subscriptionBalanceLoading: false
        )
    }
    .environmentObject(themeManager)
    .background(themeManager.currentTheme.backgroundColor)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
