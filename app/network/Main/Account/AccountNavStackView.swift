//
//  AccountView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/10.
//

import SwiftUI
import URnetworkSdk

struct AccountNavStackView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @StateObject private var viewModel: ViewModel = ViewModel()
    
    @StateObject var accountPreferencesViewModel: AccountPreferencesViewModel
    @StateObject var earningsViewModel: EarningsViewModel
    @StateObject var accountPointsStore: AccountPointsStore
    
    @ObservedObject var networkUserViewModel: NetworkUserViewModel
    @ObservedObject var referralLinkViewModel: ReferralLinkViewModel
    
    let api: SdkApi
    let urApiService: UrApiServiceProtocol
    let device: SdkDeviceRemote
    let logout: () -> Void
    let providerCountries: [SdkConnectLocation]
    let networkReliabilityWindow: SdkReliabilityWindow?
    let fetchNetworkReliability: () async -> Void
    let isPro: Bool
    
    init(
        api: SdkApi,
        urApiService: UrApiServiceProtocol,
        device: SdkDeviceRemote,
        logout: @escaping () -> Void,
        networkUserViewModel: NetworkUserViewModel,
        referralLinkViewModel: ReferralLinkViewModel,
        providerCountries: [SdkConnectLocation],
        networkReliabilityWindow: SdkReliabilityWindow?,
        fetchNetworkReliability: @escaping () async -> Void,
        isPro: Bool
    ) {
        self.api = api
        _accountPreferencesViewModel = StateObject.init(wrappedValue: AccountPreferencesViewModel(
                api: api
            )
        )
        _earningsViewModel = StateObject(wrappedValue: EarningsViewModel(
            client: EarningsSdkClient(api: api, urApiService: urApiService, device: device)
        ))
        _accountPointsStore = StateObject.init(wrappedValue: AccountPointsStore(api: api))
        
        self.networkUserViewModel = networkUserViewModel
        
        self.device = device
        self.logout = logout
        self.referralLinkViewModel = referralLinkViewModel
        self.urApiService = urApiService
        self.providerCountries = providerCountries
        self.networkReliabilityWindow = networkReliabilityWindow
        self.fetchNetworkReliability = fetchNetworkReliability
        self.isPro = isPro
    }
    
    var body: some View {
        
        let parsedJwt = deviceManager.parsedJwt
        let networkName = parsedJwt?.networkName ?? ""
        
        NavigationStack(
            path: $viewModel.navigationPath
        ) {
            
            AccountRootView(
                navigate: viewModel.navigate,
                logout: logout,
                api: api, // todo - deprecate
                urApiService: urApiService,
                referralLinkViewModel: referralLinkViewModel,
                accountPointsStore: accountPointsStore,
                networkName: networkName,
                meanReliabilityWeight: networkReliabilityWindow?.meanReliabilityWeight ?? 0,
                isPro: isPro
            )
            .navigationTitle("Account")
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationDestination(for: AccountNavigationPath.self) { path in
                switch path {
                    
                case .profile:
                    ProfileView(
                        api: api,
                        back: viewModel.back,
                        networkName: networkName,
                        userAuth: networkUserViewModel.networkUser?.userAuth,
                        needsNameClaim: {
                            guard let networkUser = networkUserViewModel.networkUser else { return false }
                            let hasIdentityMethod = authTypesContains(networkUser.authTypes, "email")
                                || authTypesContains(networkUser.authTypes, "phone")
                                || authTypesContains(networkUser.authTypes, "google")
                                || authTypesContains(networkUser.authTypes, "apple")
                                || authTypesContains(networkUser.authTypes, "solana")
                            return !hasIdentityMethod
                        }()
                    )
                    .background(themeManager.currentTheme.backgroundColor)
                    .navigationTitle("Profile")
                    
                case .settings:
                    SettingsView(
                        api: urApiService,
                        clientId: device.getClientId(),
                        accountPreferencesViewModel: accountPreferencesViewModel,
                        navigate: viewModel.navigate,
                        providerCountries: providerCountries,
                        networkUserViewModel: networkUserViewModel
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    .navigationTitle("Settings")
                    
                case .earnings:
                    EarningsView(
                        navigate: viewModel.navigate,
                        accountPointsStore: accountPointsStore,
                        networkReliabilityWindow: networkReliabilityWindow,
                        fetchNetworkReliability: fetchNetworkReliability,
                        viewModel: earningsViewModel
                    )
                    .navigationTitle("Earnings")
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

                case .referrals:
                    ReferralsView(
                        api: urApiService,
                        referralLinkViewModel: referralLinkViewModel,
                        accountPointsStore: accountPointsStore
                    )
                    .navigationTitle("Refer and earn")
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    
                case .blockedLocations:

                    BlockedLocationsView(
                        api: urApiService,
                        countries: providerCountries
                    )
                    .navigationTitle("Blocked Locations")
                    .background(themeManager.currentTheme.backgroundColor)
                 
                case .transferBalanceCodes:

                    TransferBalanceCodesView(api: urApiService)
                        .navigationTitle("Balance Codes")
                        .background(themeManager.currentTheme.backgroundColor)

                case .providerContracts:

                    ContractDetailsView(mode: .provider)
                        .navigationTitle("Provider contracts")
                        .background(themeManager.currentTheme.backgroundColor)

                case .providerIdentities:

                    ProviderIdentitiesView()
                        .navigationTitle("Provider Identities")
                        .background(themeManager.currentTheme.backgroundColor)

                case .developer:

                    DeveloperView()
                        .navigationTitle("Developer")
                        .background(themeManager.currentTheme.backgroundColor)

                }
                
            }
        }
    }

}

//#Preview {
//    AccountNavStackView(
//        api: SdkApi(),
//        device: SdkDeviceRemote(),
//        provideWhileDisconnected: .constant(true),
//        logout: {},
//        networkUserViewModel: NetworkUserViewModel(api: SdkApi())
//    )
//    .environmentObject(ThemeManager.shared)
//}
