//
//  ConnectView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/11/21.
//

import SwiftUI
import URnetworkSdk

struct ConnectView: View {
    
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var snackbarManager: UrSnackbarManager
    @Environment(\.requestReview) private var requestReview
    
    @StateObject private var viewModel: ViewModel
    
    var logout: () -> Void
    var api: SdkApi
    @ObservedObject var providerListSheetViewModel: ProviderListSheetViewModel
    var tunnelConnected: Bool
    
    init(
        api: SdkApi,
        logout: @escaping () -> Void,
        device: SdkDeviceRemote?,
        connectViewController: SdkConnectViewController?,
        providerListSheetViewModel: ProviderListSheetViewModel,
        tunnelConnected: Bool
    ) {
        _viewModel = StateObject.init(wrappedValue: ViewModel(
            api: api,
            device: device,
            connectViewController: connectViewController
        ))
        self.logout = logout
        self.api = api
        self.providerListSheetViewModel = providerListSheetViewModel
        self.tunnelConnected = tunnelConnected
        
        // adds clear button to search providers text field
        UITextField.appearance().clearButtonMode = .whileEditing
    }
    
    var body: some View {
        
        let isGuest = deviceManager.parsedJwt?.guestMode ?? true
        
        VStack {
            
//            HStack {
//                Spacer()
//                AccountMenu(
//                    isGuest: isGuest,
//                    logout: logout,
//                    api: api,
//                    isPresentedCreateAccount: $viewModel.isPresentedCreateAccount
//                )
//            }
//            .frame(height: 32)
            
            Spacer()
            
            ConnectButtonView(
                gridPoints:
                    viewModel.gridPoints,
                gridWidth: viewModel.gridWidth,
                connectionStatus: viewModel.connectionStatus,
                windowCurrentSize: viewModel.windowCurrentSize,
                connect: viewModel.connect,
                disconnect: viewModel.disconnect,
                tunnelConnected: tunnelConnected
            )
            
            Spacer()
            
            Button(action: {
                providerListSheetViewModel.isPresented = true
            }) {

                HStack {
                    
                    if let selectedProvider = viewModel.selectedProvider, selectedProvider.connectLocationId?.bestAvailable != true {
   
                        Image("ur.symbols.tab.connect")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(viewModel.getProviderColor(selectedProvider))
                        
                        Spacer().frame(width: 16)
                        
                        VStack(alignment: .leading) {
                            Text(selectedProvider.name)
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                            
                            if selectedProvider.providerCount > 0 {
            
                                Text("\(selectedProvider.providerCount) providers")
                                    .font(themeManager.currentTheme.secondaryBodyFont)
                                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                            }
            
                            
                        }
                    } else {
           
                        Image("ur.symbols.tab.connect")
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(.urCoral)
                        
                        Spacer().frame(width: 16)
                        
                        VStack(alignment: .leading) {
                            Text("Best available provider")
                                .font(themeManager.currentTheme.bodyFont)
                                .foregroundColor(themeManager.currentTheme.textColor)
                        }
                        
                    }
                    
                    Spacer().frame(width: 8)
                    
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                
            }
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .clipShape(.capsule)
            
        }
        .onAppear {
            
            /**
             * Create callback function for prompting rating
             */
            viewModel.requestReview = {
                Task {
                    
                    if let device = deviceManager.device {
                        
                        if device.getShouldShowRatingDialog() {
                            device.setCanShowRatingDialog(false)
                            try await Task.sleep(for: .seconds(2))
                            requestReview()
                        }
                        
                    }
                    
                }
            }
            
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $providerListSheetViewModel.isPresented) {
            
            NavigationStack {
                
                ProviderListSheetView(
                    selectedProvider: viewModel.selectedProvider,
                    connect: { provider in
                        viewModel.connect(provider)
                        providerListSheetViewModel.isPresented = false
                    },
                    connectBestAvailable: {
                        viewModel.connectBestAvailable()
                        providerListSheetViewModel.isPresented = false
                    },
                    providerCountries: viewModel.providerCountries,
                    providerPromoted: viewModel.providerPromoted,
                    providerDevices: viewModel.providerDevices,
                    providerRegions: viewModel.providerRegions,
                    providerCities: viewModel.providerCities,
                    providerBestSearchMatches: viewModel.providerBestSearchMatches
                )
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $viewModel.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search providers"
                )
                .toolbar {
                    
                    ToolbarItem(placement: .principal) {
                        Text("Available providers")
                            .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                    }
                    
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            providerListSheetViewModel.isPresented = false
                        }) {
                            Image(systemName: "xmark")
                        }
                    }
                }
                .refreshable {
                    let _ = await viewModel.filterLocations(viewModel.searchQuery)
                }
                .onAppear {
                    Task {
                        let _ = await viewModel.filterLocations(viewModel.searchQuery)
                    }
                }

                
            }
            .background(themeManager.currentTheme.backgroundColor)

            
        }
        
        // upgrade guest account flow
        .fullScreenCover(isPresented: $viewModel.isPresentedCreateAccount) {
            LoginNavigationView(
                api: api,
                cancel: {
                    viewModel.isPresentedCreateAccount = false
                },
                
                handleSuccess: { jwt in
                    Task {
                        await handleSuccessWithJwt(jwt)
                        viewModel.isPresentedCreateAccount = false
                    }
                }
            )
        }
    }
    
    private func handleSuccessWithJwt(_ jwt: String) async {
        
        let result = await deviceManager.authenticateNetworkClient(jwt)
        
        if case .failure(let error) = result {
            print("[ContentView] handleSuccessWithJwt: \(error.localizedDescription)")
            
            snackbarManager.showSnackbar(message: "There was an error creating your network. Please try again later.")
            
            return
        }
        
        // TODO: fade out login flow
        // TODO: create navigation view model and switch to main app instead of checking deviceManager.device
        
    }
        
}

#Preview {
    ConnectView(
        api: SdkApi(),
        logout: {},
        device: nil,
        connectViewController: nil,
        providerListSheetViewModel: ProviderListSheetViewModel(),
        tunnelConnected: true
    )
}
