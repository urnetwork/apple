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
    var handleSuccess: NetworkLoginHandler

    let loginOrigin: NetworkLoginOrigin

    // A view hierarchy owns one API. Origin identity recreates it on every
    // accepted space/session change; retained old work still uses its old API.
    private var urApiService: UrApiServiceProtocol { UrApiService(api: api) }

    init(api: SdkApi, loginOrigin: NetworkLoginOrigin, cancel: (() -> Void)? = nil, handleSuccess: @escaping NetworkLoginHandler) {
        self.api = api
        self.loginOrigin = loginOrigin
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
                handleSuccess: { jwt, request in
                    await handleSuccess(.existing(jwt), request)
                }
            )
            .id(loginOrigin.id)
            .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
            .navigationDestination(for: LoginInitialNavigationPath.self) { path in
                switch path {
                    case .password(let userAuth):
                        LoginPasswordView(
                            userAuth: userAuth,
                            navigate: viewModel.navigate,
                            handleSuccess: { jwt, request in
                                await handleSuccess(.existing(jwt), request)
                            },
                            api: api
                        )
                        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    case .createNetwork(let authLoginArgs, let bittensorWalletId):
                        CreateNetworkView(
                            authLoginArgs: authLoginArgs,
                            bittensorWalletId: bittensorWalletId,
                            navigate: viewModel.navigate,
                            handleSuccess: { jwt, request in
                                await handleSuccess(.created(jwt), request)
                            },
                            api: api,
                            urApiService: urApiService
                        )
                        .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                    case .verify(let userAuth, let sendNotice):
                        CreateNetworkVerifyView(
                            userAuth: userAuth,
                            sendNotice: sendNotice,
                            api: api,
                            backToRoot: viewModel.backToRoot,
                            handleSuccess: { jwt, request in
                                await handleSuccess(.created(jwt), request)
                            }
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
                        handleSuccess: { jwt, request in
                            await handleSuccess(.existing(jwt), request)
                        },
                        back: viewModel.back
                    )
                    .background(themeManager.currentTheme.backgroundColor.ignoresSafeArea())
                case .authCode:
                    LoginAuthCodeView(
                        urApiService: urApiService,
                        handleSuccess: { jwt, request in
                            await handleSuccess(.existing(jwt), request)
                        },
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
        .environment(\.networkLoginContext, NetworkLoginContext(manager: deviceManager, origin: loginOrigin))
        // why the server signed this app out, when it said (SignedOutNotice):
        // shown once, dismissing it clears it
        .alert(
            deviceManager.signedOutNotice?.message ?? "",
            isPresented: Binding(
                get: { deviceManager.signedOutNotice != nil },
                set: { presented in
                    if !presented {
                        deviceManager.dismissSignedOutNotice()
                    }
                }
            ),
            presenting: deviceManager.signedOutNotice
        ) { _ in
            Button(String(localized: "Got it")) {
                deviceManager.dismissSignedOutNotice()
            }
        }
    }
}

#Preview {
    LoginNavigationView(
        api: SdkApi(),
        loginOrigin: NetworkLoginOrigin(),
        handleSuccess: { _, _ in }
    )
}
