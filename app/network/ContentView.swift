//
//  ContentView.swift
//  network
//
//  Created by brien on 11/18/24.
//

import SwiftUI
import URnetworkSdk
import GoogleSignIn

// A tiny acceptance-only value that remains explicit in the accessibility
// tree. macOS can expose a clipped Text by identifier while leaving its
// inferred label empty, so neither the label nor value may rely on inference.
struct AcceptanceMarker: View {
    let identifier: String
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 1))
            .frame(width: 1, height: 1)
            .clipped()
            .opacity(0.01)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(Text(value))
            .accessibilityValue(Text(value))
    }
}

struct ContentView: View {
    
    @StateObject var viewModel = ViewModel()
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var connectViewModel: ConnectViewModel
    @StateObject private var snackbarManager = UrSnackbarManager()
    @StateObject private var connectWalletProviderViewModel = ConnectWalletProviderViewModel()
    @ObservedObject private var insufficientBalanceNoticePosts = InsufficientBalanceNoticePosts.shared
    
    @State private var opacity: Double = 0.0
    @State private var updatePathWorkItem: DispatchWorkItem?
    
    @EnvironmentObject var themeManager: ThemeManager
    
    @State var welcomeAnimationComplete: Bool = true
    @State var introductionComplete: Bool = true

    // a sign-in the network's client limit refused: the notice, then the
    // device list, where a removal runs the sign-in again
    @State private var signInDeviceLimit: SignInDeviceLimit? = nil
    @State private var signInManageDevices: SignInDeviceLimit? = nil
    // why the last retry of that sign-in failed, above the list
    @State private var signInRetryMessage: String? = nil
    
    var body: some View {
        ZStack {
            
            if deviceManager.storedAuthenticationStartupState == .retryableFailure {
                VStack(spacing: 16) {
                    Text("Couldn't restore your session")
                        .font(.headline)
                    Text("Try again to continue.")
                        .multilineTextAlignment(.center)
                    Button("Try again") {
                        deviceManager.retryStoredAuthenticationStartup()
                    }
                }
                .padding()
            } else if deviceManager.storedAuthenticationStartupState == .loading {
                ProgressView("Loading...")
            } else if let api = deviceManager.api {
                
                switch viewModel.contentViewPath {
                    
                case .uninitialized:
                    ProgressView()
                case .authenticate:
                    LoginNavigationView(
                        api: api,
                        loginOrigin: deviceManager.networkLoginOrigin,
                        handleSuccess: handleSuccessWithJwt
                    )
                    .id(deviceManager.networkLoginOrigin.id)
                    .opacity(opacity)

                case .main:
                    if let device = deviceManager.device,
                       deviceManager.vpnManager != nil
                        || deviceManager.startupMode == .hardwareNoVPN {
                        
                        let networkId = deviceManager.parsedJwt?.networkId
                        
                        MainView(
                            api: api,
                            device: device,
                            logout: {
                                
                                // warned first while the payout key isn't saved
                                BittensorKeySignOut.shared.request(networkId: networkId?.idStr) {
                                    Task {
                                        // no connect from here; the disconnect
                                        // reaches the sdk before the sign out,
                                        // of this account only
                                        await connectViewModel.signOut(
                                            currentDevice: { deviceManager.device },
                                            logout: {
                                                // the session's pending product events go out before it ends
                                                ClientEvents.shared.stop()
                                                deviceManager.logout()
                                            }
                                        )
                                    }
                                }
                                
                            },
                            welcomeAnimationComplete: $welcomeAnimationComplete,
                            networkId: networkId,
                            introductionComplete: $introductionComplete,
                            isPro: deviceManager.isPro
                        )
                        .opacity(opacity)

                    } else {
                        ProgressView("Loading...")
                    }
                    
                }
                
            } else {
                ProgressView()
            }
            
            UrSnackBar(message: snackbarManager.message, isVisible: snackbarManager.isVisible, onTap: snackbarManager.dismiss)
                .padding(.bottom, 50)
                // one pane while a fold divides the window (apple/DUO.md item 11)
                .overlayOffTheFold()

            // Present only in acceptance builds.  XCUITest asserts this
            // compile-time marker before touching credentials, which prevents
            // a stale installed app from masquerading as the local build.
            if let acceptanceBuildID {
                AcceptanceMarker(
                    identifier: "acceptance.build.id",
                    value: acceptanceBuildID
                )
                AcceptanceMarker(
                    identifier: "acceptance.environment",
                    value: NetworkConfig.officialEnvName
                )
                if let networkID = deviceManager.parsedJwt?.networkId?.idStr {
                    AcceptanceMarker(
                        identifier: "acceptance.network.id",
                        value: networkID
                    )
                }
                if let clientID = deviceManager.device?.getClientId()?.idStr {
                    AcceptanceMarker(
                        identifier: "acceptance.client.id",
                        value: clientID
                    )
                }
                AcceptanceMarker(
                    identifier: "acceptance.insufficientBalance.notifications",
                    value: "\(insufficientBalanceNoticePosts.count)"
                )
            }

            #if DEBUG && URNETWORK_HARDWARE_UI_TESTING && os(iOS)
            if deviceManager.startupMode == .hardwareNoVPN {
                AcceptanceMarker(
                    identifier: "hardware.startup.no-vpn.active",
                    value: "ready"
                )
                AcceptanceMarker(
                    identifier: "hardware.startup.device-initializer-invocation-count",
                    value: "\(deviceManager.startupInitializationInvocationCount)"
                )
                AcceptanceMarker(
                    identifier: "hardware.startup.vpn-manager-invocation-count",
                    value: "\(deviceManager.vpnManagerInitializationInvocationCount)"
                )
            }
            #endif
            
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(BittensorKeySignOutAlert())
        // the client limit refused the sign-in: what to do, and the device
        // list. No Get Pro here: the purchase needs a signed-in device, and
        // the server signs the apps in and holds a free plan at connect,
        // where the connect notice offers it.
        .alert(
            ClientLimitNotice.title,
            isPresented: Binding(
                get: { signInDeviceLimit != nil },
                set: { presented in
                    if !presented {
                        signInDeviceLimit = nil
                    }
                }
            ),
            presenting: signInDeviceLimit
        ) { limit in
            Button("Manage devices") {
                signInDeviceLimit = nil
                signInRetryMessage = nil
                signInManageDevices = limit
            }
            .accessibilityIdentifier("acceptance.clientLimit.signIn.manageDevices")
            Button("Cancel", role: .cancel) {
                signInDeviceLimit = nil
            }
        } message: { limit in
            Text(verbatim: ClientLimitNotice.body(offersUpgrade: limit.offersUpgrade))
        }
        .sheetOffTheFold(item: $signInManageDevices) { limit in
            ManageDevicesSheet(
                store: ManageDevicesStore.forSignIn(
                    api: limit.api,
                    networkJwt: limit.login.jwt,
                    retry: {
                        retrySignIn(limit)
                    }
                ),
                message: signInRetryMessage ?? ClientLimitNotice.body(offersUpgrade: limit.offersUpgrade),
                dismiss: {
                    signInManageDevices = nil
                }
            )
            .environmentObject(themeManager)
        }
        .environmentObject(deviceManager)
        .background(themeManager.currentTheme.backgroundColor)
        .environmentObject(snackbarManager)
        .environmentObject(connectWalletProviderViewModel)
        .onReceive(deviceManager.$device) { device in
  
            updatePath()

            // the product-event sender lives with the device session: bound to
            // its network space when the session comes up, closed when it ends
            if device != nil, let networkSpace = deviceManager.networkSpace {
                ClientEvents.shared.start(networkSpace: networkSpace)
            } else if device == nil {
                ClientEvents.shared.stop(timeoutMillis: 500)
            }
            
        }
        .onReceive(deviceManager.$storedAuthenticationStartupState) { _ in
            updatePath()
        }
        .onReceive(connectViewModel.$connectionStatus) { status in
            // once per network: the first successful connection
            if status == .connected, let networkId = deviceManager.parsedJwt?.networkId?.idStr {
                ClientEvents.shared.connectFirst(networkId: networkId)
            }
        }
        
    }

    private var acceptanceBuildID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "URAcceptanceBuildID") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return nil
        }
        return value
    }
    
    private func updatePath() {
        updatePathWorkItem?.cancel()

        withAnimation {
            opacity = 0.0
        }

        let workItem = DispatchWorkItem {
            viewModel.updatePath(
                deviceManager.device,
                startupState: deviceManager.storedAuthenticationStartupState
            )
            withAnimation {
                opacity = 1.0
            }
        }
        updatePathWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func handleSuccessWithJwt(_ login: NetworkLogin, request: NetworkLoginRequest) async {
        let result = await deviceManager.authenticateNetworkClient(login, request: request, accepted: {
            self.welcomeAnimationComplete = false
            self.introductionComplete = !login.newNetwork
        })
        guard request.isCurrent else { return }
        if case .failure(let error) = result, !(error is CancellationError) {
            if let clientLimit = error as? NetworkClientLimitError {
                // the network's client limit refused the sign-in: say what to
                // do, not that creating the network failed, and offer the
                // device list
                signInDeviceLimit = SignInDeviceLimit(
                    login: login,
                    api: request.api,
                    offersUpgrade: clientLimit.offersUpgrade
                )
            } else {
                snackbarManager.showSnackbar(message: String(localized: "There was an error creating your network. Please try again later."))
            }
        }
    }

    /**
     * A removal in the device list freed a slot: the refused sign-in again,
     * with the same login, as a new request (a request registers once) of the
     * login view now shown. The refused attempt was accepted before the
     * server refused it, which retired its login view's origin, so the
     * retry starts from the current one. Success leaves the list for the
     * app; another refusal keeps it open, saying why.
     */
    private func retrySignIn(_ limit: SignInDeviceLimit) {
        guard let request = deviceManager.beginNetworkLoginRequest(origin: deviceManager.networkLoginOrigin) else {
            return
        }
        Task {
            let result = await deviceManager.authenticateNetworkClient(limit.login, request: request, accepted: {
                self.welcomeAnimationComplete = false
                self.introductionComplete = !limit.login.newNetwork
            })
            guard request.isCurrent else { return }
            switch result {
            case .success:
                signInManageDevices = nil
                signInRetryMessage = nil
            case .failure(let error):
                if error is CancellationError {
                    return
                }
                if let clientLimit = error as? NetworkClientLimitError {
                    signInRetryMessage = ClientLimitNotice.body(offersUpgrade: clientLimit.offersUpgrade)
                } else {
                    signInRetryMessage = String(localized: "There was an error creating your network. Please try again later.")
                }
            }
        }
    }
    
}

/// A sign-in the network's client limit refused, with what runs it again: its
/// login (the network's sign-in token), and the api it signs in on.
private struct SignInDeviceLimit: Identifiable {
    let id = UUID()
    let login: NetworkLogin
    let api: SdkApi
    let offersUpgrade: Bool
}
//
//#Preview {
//    ContentView(
//        api: SdkBringYourApi()
//    )
//        .environmentObject(ThemeManager.shared)
//}
