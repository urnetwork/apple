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
    
    @StateObject private var guestUpgradeViewModel: GuestUpgradeViewModel
    
    @EnvironmentObject var themeManager: ThemeManager
    
    var api: SdkApi
    let urApiService: UrApiServiceProtocol
    var cancel: (() -> Void)? = nil
    var handleSuccess: (_ jwt: String) async -> Void
    
    init(api: SdkApi, cancel: (() -> Void)? = nil, handleSuccess: @escaping (_ jwt: String) async -> Void) {
        self.api = api
        self.urApiService = UrApiService(api: api)
        self.cancel = cancel
        self.handleSuccess = handleSuccess
        _guestUpgradeViewModel = StateObject(wrappedValue: GuestUpgradeViewModel(api: api))
    }
    
    var body: some View {
        NavigationStack(
            path: $viewModel.navigationPath
        ) {
            LoginInitialView(
                urApiService: urApiService,
                navigate: viewModel.navigate,
                cancel: cancel,
                handleSuccess: handleSuccess,
                guestUpgradeViewModel: guestUpgradeViewModel
            )
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationDestination(for: LoginInitialNavigationPath.self) { path in
                switch path {
                    case .password(let userAuth):
                        LoginPasswordView(
                            userAuth: userAuth,
                            navigate: viewModel.navigate,
                            handleSuccess: handleSuccess,
                            guestUpgradeViewModel: guestUpgradeViewModel,
                            api: api
                        )
                        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    case .createNetwork(let authLoginArgs):
                        CreateNetworkView(
                            authLoginArgs: authLoginArgs,
                            navigate: viewModel.navigate,
                            handleSuccess: handleSuccess,
                            api: api
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
