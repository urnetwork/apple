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
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    // a regular-width window shows the list beside the chosen screen
    @Environment(\.isRegularWidth) private var isRegularWidth
    
    @StateObject var accountPreferencesViewModel: AccountPreferencesViewModel
    @StateObject var earningsViewModel: EarningsViewModel
    @StateObject var usdcWalletsViewModel: UsdcWalletsViewModel
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
        _usdcWalletsViewModel = StateObject(wrappedValue: UsdcWalletsViewModel(
            client: UsdcWalletsSdkClient(api: api, urApiService: urApiService)
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

        Group {
            if isRegularWidth {
                listDetail(networkName: networkName)
            } else {
                stack(networkName: networkName)
            }
        }
        // an onboarding email's widgets link lands on Account > Widgets, a
        // Top 200 sign link on Account > Sign fleet binding
        .onReceive(deepLinkRouter.$pendingAccountPath) { path in
            guard path != nil, let path = deepLinkRouter.consumeAccountPath() else { return }
            if isRegularWidth {
                viewModel.select(path)
            } else {
                viewModel.open(path)
            }
        }
    }

    /// The phone's layout: the list, and each screen pushed over it.
    private func stack(networkName: String) -> some View {
        NavigationStack(
            path: $viewModel.navigationPath
        ) {
            
            accountRoot(networkName: networkName, navigate: viewModel.navigate)
                .navigationDestination(for: AccountNavigationPath.self) { path in
                    destination(path, networkName: networkName)
                }
        }
    }

    /**
     * A regular-width window: the list on the left and the chosen screen on
     * the right, split at the fold of a foldable, else 40/60. The screens the
     * chosen one opens push over it on the right.
     */
    private func listDetail(networkName: String) -> some View {
        GeometryReader { geometry in

            let panes = SplitLayout.panes(size: geometry.size, sideBySide: true, fold: geometry.windowFold)

            ZStack {

                NavigationStack {
                    accountRoot(networkName: networkName, navigate: viewModel.select)
                }
                .frame(width: panes.firstEnd)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(themeManager.currentTheme.borderBaseColor)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                NavigationStack(path: $viewModel.detailPath) {
                    Group {
                        if let selection = viewModel.selection {
                            destination(selection, networkName: networkName)
                        } else {
                            // nothing chosen yet
                            Image("ur.symbols.tab.account")
                                .renderingMode(.template)
                                .foregroundColor(themeManager.currentTheme.textFaintColor)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                        }
                    }
                    .navigationDestination(for: AccountNavigationPath.self) { path in
                        destination(path, networkName: networkName)
                    }
                }
                .frame(width: geometry.size.width - panes.secondStart)
                .frame(maxWidth: .infinity, alignment: .trailing)

            }
        }
    }

    /// The list: the plan, points and the Account screens.
    private func accountRoot(networkName: String, navigate: @escaping (AccountNavigationPath) -> Void) -> some View {
        AccountRootView(
            navigate: navigate,
            logout: logout,
            api: api, // todo - deprecate
            urApiService: urApiService,
            referralLinkViewModel: referralLinkViewModel,
            accountPointsStore: accountPointsStore,
            networkName: networkName,
            meanReliabilityWeight: networkReliabilityWindow?.meanReliabilityWeight ?? 0,
            isPro: isPro,
            selection: isRegularWidth ? viewModel.selection : nil
        )
        .navigationTitle("Account")
        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
    }

    @ViewBuilder
    private func destination(_ path: AccountNavigationPath, networkName: String) -> some View {
        switch path {

        case .profile:
            ProfileView(
                api: api,
                back: viewModel.back,
                networkName: networkName,
                userAuth: networkUserViewModel.networkUser.flatMap(passwordResetUserAuth),
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

        case .sessions:

            // the account's signed-in sessions, built on the account
            // api (the controller needs no device)
            SessionsView(api: api)
                .navigationTitle("Sessions")
                .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

        case .apiKeys:

            // the network's API keys, on the account api (no device)
            ApiKeysView(api: api)
                .navigationTitle("API keys")
                .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

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
                viewModel: earningsViewModel,
                usdcViewModel: usdcWalletsViewModel,
                consentClient: NetworkConsentSdkClient(api: api)
            )
            .navigationTitle("Earnings")
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

        case .top200Sign(let link):
            Top200SignView(
                device: Top200SdkSignDevice(device: device),
                link: link
            )
            .navigationTitle("Sign fleet binding")
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

        case .referrals:
            ReferralsView(
                api: urApiService,
                referralLinkViewModel: referralLinkViewModel,
                accountPointsStore: accountPointsStore
            )
            .navigationTitle("Refer and earn")
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

        case .widgets:
            WidgetsView()
                .navigationTitle("Widgets")
                .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

        case .extenders:

            ExtendersView()
                .navigationTitle("Extenders")
                .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())

        case .vless:

            VlessSettingsView()
                .navigationTitle("VLESS")
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

        case .licenses:

            LicensesView(device: device, navigate: viewModel.navigate)
                .navigationTitle("Licenses")
                .background(themeManager.currentTheme.backgroundColor)

        case .licenseDetail(let entry):

            LicenseDetailView(entry: entry)
                .navigationTitle(entry.name)
                .background(themeManager.currentTheme.backgroundColor)

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
