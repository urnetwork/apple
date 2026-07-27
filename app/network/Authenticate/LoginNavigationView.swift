//
//  LoginNavigationView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import SwiftUI
import URnetworkSdk

struct LoginNavigationView: View {
    
    @StateObject private var viewModel = ViewModel()
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    
    var api: SdkApi
    var cancel: (() -> Void)? = nil
    var handleSuccess: (_ jwt: String) async -> Void

    // Built from a live closure over `deviceManager.api` (an @EnvironmentObject,
    // not available yet at init time) rather than the `api` snapshot passed
    // in, so that switching the active network space (Settings > Change
    // Network API) while this view is on screen is picked up immediately by
    // every subsequent API call - including wallet-auth challenge/login,
    // which previously kept hitting the network active when the login flow
    // was first presented until the app was restarted.
    private var urApiService: UrApiServiceProtocol {
        UrApiService(apiProvider: { [weak deviceManager] in
            deviceManager?.api ?? api
        })
    }
    
    init(api: SdkApi, cancel: (() -> Void)? = nil, handleSuccess: @escaping (_ jwt: String) async -> Void) {
        self.api = api
        self.cancel = cancel
        self.handleSuccess = handleSuccess
    }
    
    var body: some View {
        NavigationStack(
            path: $viewModel.navigationPath
        ) {
            LoginInitialView(
                urApiService: urApiService,
                navigate: viewModel.navigate,
                cancel: cancel,
                handleSuccess: handleSuccess
            )
            .id(deviceManager.activeHostName)
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationDestination(for: LoginInitialNavigationPath.self) { path in
                switch path {
                    case .password(let userAuth):
                        LoginPasswordView(
                            userAuth: userAuth,
                            navigate: viewModel.navigate,
                            handleSuccess: handleSuccess,
                            api: api
                        )
                        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    case .createNetwork(let authLoginArgs):
                        CreateNetworkView(
                            authLoginArgs: authLoginArgs,
                            navigate: viewModel.navigate,
                            handleSuccess: handleSuccess,
                            api: api,
                            urApiService: urApiService
                        )
                        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    case .verify(let userAuth):
                        CreateNetworkVerifyView(
                            userAuth: userAuth,
                            api: api,
                            backToRoot: viewModel.backToRoot,
                            handleSuccess: handleSuccess
                        )
                        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                case .resetPassword(let userAuth):
                    ResetPasswordView(
                        userAuth: userAuth,
                        popNavigationStack: viewModel.back,
                        api: api
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                case .seedphrase:
                    LoginSeedphraseView(
                        urApiService: urApiService,
                        handleSuccess: handleSuccess,
                        back: viewModel.back
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                case .createInstant:
                    CreateNetworkInstantView(
                        urApiService: urApiService,
                        handleSuccess: handleSuccess,
                        back: viewModel.back
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                }
            }
        }
    }
}

#Preview {
    LoginNavigationView(
        api: SdkApi(),
        handleSuccess: {_ in }
    )
}
